// See linuxmedia.h. Everything here is called from one thread at a time (the Indexer's preparation thread)
// and holds no state between calls.

#include "linuxmedia.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>

#include <libexif/exif-data.h>
#include <libexif/exif-content.h>
#include <libexif/exif-entry.h>
#include <libexif/exif-tag.h>
#include <libexif/exif-format.h>
#include <libexif/exif-byte-order.h>

#include <tesseract/capi.h>

#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "stb_image_write.h"

// MARK: decoding

static AVCodecContext *open_decoder(AVStream *stream) {
    const AVCodec *codec = avcodec_find_decoder(stream->codecpar->codec_id);
    if (!codec) return NULL;
    AVCodecContext *context = avcodec_alloc_context3(codec);
    if (!context) return NULL;
    if (avcodec_parameters_to_context(context, stream->codecpar) < 0 || avcodec_open2(context, codec, NULL) < 0) {
        avcodec_free_context(&context);
        return NULL;
    }
    return context;
}

/// The stream's first decoded frame (a still image is one packet, one frame; some need the decoder flushed).
static AVFrame *first_frame(AVFormatContext *format, AVCodecContext *decoder, int stream_index) {
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    while (av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == stream_index && avcodec_send_packet(decoder, packet) >= 0) {
            while (avcodec_receive_frame(decoder, frame) >= 0) {
                if (frame->width > 0 && frame->height > 0 && frame->data[0]) {
                    av_packet_free(&packet);
                    return frame;
                }
                av_frame_unref(frame);
            }
        }
        av_packet_unref(packet);
    }
    avcodec_send_packet(decoder, NULL);   // drain: some stills come out only at the end
    while (avcodec_receive_frame(decoder, frame) >= 0) {
        if (frame->width > 0 && frame->height > 0 && frame->data[0]) {
            av_packet_free(&packet);
            return frame;
        }
        av_frame_unref(frame);
    }
    av_frame_free(&frame);
    av_packet_free(&packet);
    return NULL;
}

int digup_image_dimensions(const char *path, int *width, int *height) {
    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, path, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(format, NULL) < 0) {
        avformat_close_input(&format);
        return -1;
    }
    int found = -1;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        const AVCodecParameters *parameters = format->streams[index]->codecpar;
        if (parameters->codec_type == AVMEDIA_TYPE_VIDEO && parameters->width > 0) {
            *width = parameters->width;
            *height = parameters->height;
            found = 0;
            break;
        }
    }
    avformat_close_input(&format);
    return found;
}

/// EXIF Orientation (1 the usual, 3 = 180°, 6 = 90° clockwise, 8 = 90° counter-clockwise; the mirrored 2, 4,
/// 5 and 7 are rare enough to come out as they are). 1 when the file has none.
static int exif_orientation(const char *path) {
    ExifData *exif = exif_data_new_from_file(path);
    if (!exif) return 1;
    int orientation = 1;
    ExifEntry *entry = exif_content_get_entry(exif->ifd[EXIF_IFD_0], EXIF_TAG_ORIENTATION);
    if (entry && entry->format == EXIF_FORMAT_SHORT && entry->components >= 1 && entry->data) {
        orientation = exif_get_short(entry->data, exif_data_get_byte_order(exif));
        if (orientation < 1 || orientation > 8) orientation = 1;
    }
    exif_data_unref(exif);
    return orientation;
}

/// A rotated copy of an RGB24 buffer: 3 (180°), 6 (90° clockwise) and 8 (90° counter-clockwise), the ways
/// phones hold their photos. The caller frees what comes back; `in` itself is freed here.
static uint8_t *rotated(uint8_t *in, int width, int height, int orientation, int *out_width, int *out_height) {
    const int pixels = width * height;
    uint8_t *out = malloc((size_t)pixels * 3);
    if (!out) { free(in); *out_width = 0; *out_height = 0; return NULL; }
    if (orientation == 3) {
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                const uint8_t *src = in + ((height - 1 - y) * width + (width - 1 - x)) * 3;
                uint8_t *dst = out + (y * width + x) * 3;
                dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
            }
        }
        *out_width = width; *out_height = height;
    } else {
        const int clockwise = orientation == 6;
        *out_width = height; *out_height = width;
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                const uint8_t *src = in + (y * width + x) * 3;
                const int dx = clockwise ? height - 1 - y : y;
                const int dy = clockwise ? x : width - 1 - x;
                uint8_t *dst = out + (dy * height + dx) * 3;
                dst[0] = src[0]; dst[1] = src[1]; dst[2] = src[2];
            }
        }
    }
    free(in);
    return out;
}

int digup_decode_image(const char *path, int max_pixel, uint8_t **out_pixels, int *width, int *height) {
    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, path, NULL, NULL) != 0) return -1;
    int stream_index = -1;
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (format->streams[index]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) { stream_index = (int)index; break; }
    }
    if (stream_index < 0) {
        avformat_close_input(&format);
        return -1;
    }
    AVCodecContext *decoder = open_decoder(format->streams[stream_index]);
    if (!decoder) {
        avformat_close_input(&format);
        return -1;
    }
    AVFrame *frame = first_frame(format, decoder, stream_index);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    if (!frame) return -1;

    // At most max_pixel on the longest side, never upscaled (as macOS's thumbnails are).
    const int source_w = frame->width, source_h = frame->height;
    const double scale = (source_w > max_pixel || source_h > max_pixel)
        ? (double)max_pixel / (source_w > source_h ? source_w : source_h) : 1.0;
    const int target_w = (int)(source_w * scale);
    const int target_h = (int)(source_h * scale);
    struct SwsContext *sws = sws_getContext(source_w, source_h, frame->format, target_w, target_h,
                                             AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
    uint8_t *rgb = NULL;
    if (sws) {
        rgb = malloc((size_t)target_w * target_h * 3);
        if (rgb) {
            uint8_t *target[4] = { rgb, NULL, NULL, NULL };
            int stride[4] = { target_w * 3, 0, 0, 0 };
            sws_scale(sws, (const uint8_t *const *)frame->data, frame->linesize, 0, source_h, target, stride);
        }
        sws_freeContext(sws);
    }
    av_frame_free(&frame);
    if (!rgb) return -1;

    // A phone's photo may say which way up it is; the pixels come out turned the right way.
    const int orientation = exif_orientation(path);
    if (orientation == 3 || orientation == 6 || orientation == 8) {
        int w = 0, h = 0;
        uint8_t *turned = rotated(rgb, target_w, target_h, orientation, &w, &h);
        if (!turned) return -1;
        *out_pixels = turned;
        *width = w;
        *height = h;
        return 0;
    }
    *out_pixels = rgb;
    *width = target_w;
    *height = target_h;
    return 0;
}

// MARK: EXIF

int digup_exif_taken(const char *path, char *out, int out_size) {
    ExifData *exif = exif_data_new_from_file(path);
    if (!exif) return -1;
    ExifEntry *entry = exif_content_get_entry(exif->ifd[EXIF_IFD_EXIF], EXIF_TAG_DATE_TIME_ORIGINAL);
    char value[64] = "";
    if (entry) exif_entry_get_value(entry, value, sizeof(value));
    exif_data_unref(exif);
    if (!value[0]) return -1;
    snprintf(out, out_size, "%s", value);
    return 0;
}

// MARK: writing

int digup_write_jpeg(const char *path, const uint8_t *rgb, int width, int height, int quality) {
    return stbi_write_jpg(path, width, height, 3, rgb, quality) == 0 ? -1 : 0;
}

int digup_write_png(const char *path, const uint8_t *rgb, int width, int height) {
    return stbi_write_png(path, width, height, 3, rgb, width * 3) == 0 ? -1 : 0;
}

// MARK: OCR

int digup_ocr(const uint8_t *rgb, int width, int height, char **out_text) {
    TessBaseAPI *api = TessBaseAPICreate();
    if (!api) return -1;
    // Its English and French are its best pair; English alone when that's all there is, none at all when
    // there's no data (the reader says nil, as Vision reads nothing in a language it doesn't know).
    if (TessBaseAPIInit3(api, NULL, "eng+fra") != 0 && TessBaseAPIInit3(api, NULL, "eng") != 0) {
        TessBaseAPIDelete(api);
        return -1;
    }
    TessBaseAPISetImage(api, rgb, width, height, 3, width * 3);
    char *read = TessBaseAPIGetUTF8Text(api);
    TessBaseAPIEnd(api);
    TessBaseAPIDelete(api);
    if (!read) return -1;
    *out_text = strdup(read);
    TessDeleteText(read);
    return *out_text ? 0 : -1;
}

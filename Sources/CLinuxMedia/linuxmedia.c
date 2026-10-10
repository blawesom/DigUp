// See linuxmedia.h. Everything here is called from one thread at a time (the Indexer's preparation thread)
// and holds no state between calls.

#include "linuxmedia.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>
#include <libavutil/display.h>

#include <libheif/heif.h>

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

// MARK: HEIC and AVIF

/// Scales a packed RGB24 buffer (with `stride`) into a fresh malloc'd buffer at most `max_pixel` on its
/// longest side — the shared resize of the image readers. NULL when libswscale declines.
static uint8_t *resized_rgb(const uint8_t *plane, int stride, int source_w, int source_h, int max_pixel,
                            int *out_w, int *out_h) {
    const double scale = (source_w > max_pixel || source_h > max_pixel)
        ? (double)max_pixel / (source_w > source_h ? source_w : source_h) : 1.0;
    const int target_w = (int)(source_w * scale), target_h = (int)(source_h * scale);
    struct SwsContext *sws = sws_getContext(source_w, source_h, AV_PIX_FMT_RGB24, target_w, target_h,
                                             AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
    if (!sws) return NULL;
    uint8_t *out = malloc((size_t)target_w * target_h * 3);
    if (out) {
        const uint8_t *sources[4] = { plane, NULL, NULL, NULL };
        const int strides[4] = { stride, 0, 0, 0 };
        uint8_t *targets[4] = { out, NULL, NULL, NULL };
        const int target_strides[4] = { target_w * 3, 0, 0, 0 };
        sws_scale(sws, sources, strides, 0, source_h, targets, target_strides);
    }
    sws_freeContext(sws);
    *out_w = target_w;
    *out_h = target_h;
    return out;
}

int digup_heif_dimensions(const char *path, int *width, int *height) {
    struct heif_context *context = heif_context_alloc();
    if (!context) return -1;
    if (heif_context_read_from_file(context, path, NULL).code != heif_error_Ok) {
        heif_context_free(context);
        return -1;
    }
    struct heif_image_handle *handle = NULL;
    if (heif_context_get_primary_image_handle(context, &handle).code != heif_error_Ok) {
        heif_context_free(context);
        return -1;
    }
    *width = heif_image_handle_get_width(handle);
    *height = heif_image_handle_get_height(handle);
    heif_image_handle_release(handle);
    heif_context_free(context);
    return *width > 0 && *height > 0 ? 0 : -1;
}

int digup_decode_heif(const char *path, int max_pixel, uint8_t **out_pixels, int *width, int *height) {
    struct heif_context *context = heif_context_alloc();
    if (!context) return -1;
    if (heif_context_read_from_file(context, path, NULL).code != heif_error_Ok) {
        heif_context_free(context);
        return -1;
    }
    struct heif_image_handle *handle = NULL;
    if (heif_context_get_primary_image_handle(context, &handle).code != heif_error_Ok) {
        heif_context_free(context);
        return -1;
    }
    struct heif_image *image = NULL;
    if (heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, NULL).code
        != heif_error_Ok) {
        heif_image_handle_release(handle);
        heif_context_free(context);
        return -1;
    }
    const int source_w = heif_image_get_width(image, heif_channel_interleaved);
    const int source_h = heif_image_get_height(image, heif_channel_interleaved);
    int stride = 0;
    const uint8_t *plane = heif_image_get_plane_readonly(image, heif_channel_interleaved, &stride);
    // Orientation comes with the EXIF metadata (this libheif has no handle API for it): a follow-up, with
    // reading when the photo was taken from the same place.
    uint8_t *out = plane ? resized_rgb(plane, stride, source_w, source_h, max_pixel, width, height) : NULL;
    heif_image_release(image);
    heif_image_handle_release(handle);
    heif_context_free(context);
    if (!out) return -1;
    *out_pixels = out;
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

// MARK: audio and video

static void free_pieces(DigupMediaPiece *pieces, int count) {
    if (!pieces) return;
    for (int i = 0; i < count; i++) free(pieces[i].path);
    free(pieces);
}

void digup_free_pieces(DigupMediaPiece *pieces, int count) { free_pieces(pieces, count); }

/// A fresh name in `folder`, the way the Mac's extractors name their scratch files.
static char *scratch_name(const char *folder, const char *extension) {
    uint8_t random[16];
    FILE *urandom = fopen("/dev/urandom", "rb");
    if (!urandom || fread(random, 1, sizeof(random), urandom) != sizeof(random)) {
        for (size_t i = 0; i < sizeof(random); i++) random[i] = (uint8_t)rand();
    }
    if (urandom) fclose(urandom);
    char hex[33];
    for (size_t i = 0; i < sizeof(random); i++) snprintf(hex + i * 2, 3, "%02x", random[i]);
    char *out = malloc(strlen(folder) + 48);
    if (out) snprintf(out, strlen(folder) + 48, "%s/%s.%s", folder, hex, extension);
    return out;
}

static int write_wav(const char *path, const int16_t *samples, int count) {
    FILE *file = fopen(path, "wb");
    if (!file) return -1;
    const uint32_t data_bytes = (uint32_t)(count * 2), rate = 16000;
    const uint16_t one = 1, two = 2, sixteen = 16;
    fwrite("RIFF", 1, 4, file);
    uint32_t riff = 36 + data_bytes; fwrite(&riff, 4, 1, file);
    fwrite("WAVE", 1, 4, file);
    fwrite("fmt ", 1, 4, file);
    uint32_t sixteen2 = 16; fwrite(&sixteen2, 4, 1, file);
    fwrite(&one, 2, 1, file); fwrite(&one, 2, 1, file);          // PCM, one channel
    fwrite(&rate, 4, 1, file);
    uint32_t byte_rate = rate * 2; fwrite(&byte_rate, 4, 1, file);
    fwrite(&two, 2, 1, file); fwrite(&sixteen, 2, 1, file);      // two bytes a sample, 16 bits
    fwrite("data", 1, 4, file);
    fwrite(&data_bytes, 4, 1, file);
    fwrite(samples, 2, count, file);
    fclose(file);
    return 0;
}

typedef struct {
    DigupMediaPiece *items;
    int count, capacity;
} PieceList;

static void pieces_add(PieceList *list, char *path, double start, double end) {
    if (list->count == list->capacity) {
        list->capacity = list->capacity ? list->capacity * 2 : 8;
        list->items = realloc(list->items, (size_t)list->capacity * sizeof(DigupMediaPiece));
    }
    list->items[list->count].path = path;
    list->items[list->count].start = start;
    list->items[list->count].end = end;
    list->count++;
}

/// Writes buffer[0 ..< count] out as a piece when it isn't silence (≈ −50 dBFS or quieter isn't worth a
/// vector); the window is consumed either way.
static void emit_window(const int16_t *buffer, size_t count, long long offset, const char *folder,
                        PieceList *pieces) {
    double sum = 0;
    for (size_t i = 0; i < count; i++) {
        const double value = (double)buffer[i] / 32768;
        sum += value * value;
    }
    if (count > 0 && (sum / (double)count) > 0.003 * 0.003) {
        char *name = scratch_name(folder, "wav");
        if (name && write_wav(name, buffer, (int)count) == 0) {
            pieces_add(pieces, name, (double)offset / 16000, (double)(offset + (long long)count) / 16000);
        } else {
            free(name);
        }
    }
}

/// Appends converted samples to the window buffer and cuts what fills a window, as the Mac's reader streams them.
static void take_samples(int16_t **buffer, size_t *buffer_count, size_t *buffer_capacity, const int16_t *samples,
                         size_t made, long long *offset, int window_samples, int hop_samples,
                         const char *folder, PieceList *pieces) {
    if (*buffer_count + made > *buffer_capacity) {
        *buffer_capacity = (*buffer_count + made) * 2;
        *buffer = realloc(*buffer, *buffer_capacity * 2);
    }
    if (!*buffer) return;
    memcpy(*buffer + *buffer_count, samples, made * 2);
    *buffer_count += made;
    while (*buffer_count >= (size_t)window_samples) {
        emit_window(*buffer, (size_t)window_samples, *offset, folder, pieces);
        *buffer_count -= (size_t)hop_samples;
        memmove(*buffer, *buffer + hop_samples, *buffer_count * 2);
        *offset += hop_samples;
    }
}

/// The index of the first stream of `type`, or -1.
static int stream_of_type(AVFormatContext *format, enum AVMediaType type) {
    for (unsigned int index = 0; index < format->nb_streams; index++) {
        if (format->streams[index]->codecpar->codec_type == type) return (int)index;
    }
    return -1;
}

int digup_audio_windows(const char *path, double window, double hop, double minimum, const char *folder,
                        DigupMediaPiece **out_pieces, int *out_count, double *out_duration) {
    *out_pieces = NULL;
    *out_count = 0;
    *out_duration = 0;
    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, path, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(format, NULL) < 0) {
        avformat_close_input(&format);
        return -1;
    }
    const int audio_index = stream_of_type(format, AVMEDIA_TYPE_AUDIO);
    double duration = format->duration != AV_NOPTS_VALUE ? (double)format->duration / AV_TIME_BASE : 0;
    if (audio_index < 0) {   // nothing to read, which is a fine answer (a video with no soundtrack)
        avformat_close_input(&format);
        *out_duration = duration;
        return 0;
    }
    AVCodecContext *decoder = open_decoder(format->streams[audio_index]);
    if (!decoder) {
        avformat_close_input(&format);
        return -1;
    }
    if (decoder->ch_layout.nb_channels == 0) av_channel_layout_default(&decoder->ch_layout, 1);
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    SwrContext *resampler = NULL;
    if (swr_alloc_set_opts2(&resampler, &mono, AV_SAMPLE_FMT_S16, 16000, &decoder->ch_layout,
                            decoder->sample_fmt, decoder->sample_rate, 0, NULL) < 0 || !resampler) {
        avcodec_free_context(&decoder);
        avformat_close_input(&format);
        return -1;
    }
    swr_init(resampler);

    const int window_samples = (int)(window * 16000), hop_samples = (int)(hop * 16000);
    int16_t *buffer = NULL;
    size_t buffer_count = 0, buffer_capacity = 0;
    long long offset = 0;   // sample index of buffer[0] in the file
    PieceList pieces = {0};
    int failed = 0;

    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    int16_t *converted = NULL;
    size_t converted_capacity = 0;
    while (!failed && av_read_frame(format, packet) >= 0) {
        if (packet->stream_index == audio_index && avcodec_send_packet(decoder, packet) >= 0) {
            while (avcodec_receive_frame(decoder, frame) >= 0) {
                const int out_samples = swr_get_out_samples(resampler, frame->nb_samples);
                if (out_samples <= 0) continue;
                if ((size_t)out_samples > converted_capacity) {
                    converted = realloc(converted, (size_t)out_samples * 2);
                    converted_capacity = out_samples;
                }
                if (!converted) { failed = 1; break; }
                uint8_t *out_plane = (uint8_t *)converted;
                const int made = swr_convert(resampler, &out_plane, out_samples,
                                             (const uint8_t **)(void *)frame->extended_data, frame->nb_samples);
                if (made > 0) take_samples(&buffer, &buffer_count, &buffer_capacity, converted, (size_t)made,
                                            &offset, window_samples, hop_samples, folder, &pieces);
            }
        }
        av_packet_unref(packet);
    }
    // What the decoder still holds, and what swresample kept back
    avcodec_send_packet(decoder, NULL);
    while (avcodec_receive_frame(decoder, frame) >= 0) {
        const int out_samples = swr_get_out_samples(resampler, frame->nb_samples);
        if (out_samples <= 0) continue;
        if ((size_t)out_samples > converted_capacity) {
            converted = realloc(converted, (size_t)out_samples * 2);
            converted_capacity = out_samples;
        }
        if (!converted) break;
        uint8_t *out_plane = (uint8_t *)converted;
        const int made = swr_convert(resampler, &out_plane, out_samples,
                                     (const uint8_t **)(void *)frame->extended_data, frame->nb_samples);
        if (made > 0) take_samples(&buffer, &buffer_count, &buffer_capacity, converted, (size_t)made,
                                   &offset, window_samples, hop_samples, folder, &pieces);
    }
    if (converted) {
        uint8_t *out_plane = (uint8_t *)converted;
        const int made = swr_convert(resampler, &out_plane, (int)converted_capacity, NULL, 0);
        if (made > 0) take_samples(&buffer, &buffer_count, &buffer_capacity, converted, (size_t)made,
                                   &offset, window_samples, hop_samples, folder, &pieces);
    }
    // The tail: new audio beyond the previous window's overlap, or the whole file if it was shorter than a window
    const long long already_covered = offset == 0 ? 0 : window_samples - hop_samples;
    if ((long long)buffer_count - already_covered >= (long long)(minimum * 16000)) {
        emit_window(buffer, buffer_count, offset, folder, &pieces);
    }
    if (duration <= 0) duration = (double)(offset + (long long)buffer_count) / 16000;

    av_frame_free(&frame);
    av_packet_free(&packet);
    free(converted);
    free(buffer);
    swr_free(&resampler);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    *out_pieces = pieces.items;
    *out_count = pieces.count;
    *out_duration = duration;
    return 0;
}

/// The frame's 8×8 grayscale average hash, for telling shots apart (the same hash the Mac's reader uses).
static uint64_t average_hash(const AVFrame *frame, struct SwsContext **sws) {
    uint8_t pixels[64];
    AVFrame *target = av_frame_alloc();
    target->format = AV_PIX_FMT_GRAY8;
    target->width = 8;
    target->height = 8;
    av_frame_get_buffer(target, 0);
    if (!*sws) {
        *sws = sws_getContext(frame->width, frame->height, frame->format, 8, 8, AV_PIX_FMT_GRAY8,
                              SWS_AREA, NULL, NULL, NULL);
    }
    if (*sws) sws_scale(*sws, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height,
                        target->data, target->linesize);
    for (int y = 0; y < 8; y++) memcpy(pixels + y * 8, target->data[0] + (size_t)y * target->linesize[0], 8);
    av_frame_free(&target);
    int mean = 0;
    for (int i = 0; i < 64; i++) mean += pixels[i];
    mean /= 64;
    uint64_t hash = 0;
    for (int i = 0; i < 64; i++) if (pixels[i] > mean) hash |= (uint64_t)1 << i;
    return hash;
}

/// How the video says it should be turned: EXIF orientation the rotations map to (1 none, 3 = 180°,
/// 6 = 90° clockwise, 8 = 90° counter-clockwise), from the display matrix phones leave in their videos.
static int display_orientation(AVCodecParameters *parameters) {
    for (int i = 0; i < parameters->nb_coded_side_data; i++) {
        if (parameters->coded_side_data[i].type != AV_PKT_DATA_DISPLAYMATRIX) continue;
        double degrees = av_display_rotation_get((const int32_t *)parameters->coded_side_data[i].data);
        while (degrees < 0) degrees += 360;
        const int quarter = ((int)(degrees / 90.0 + 0.5)) % 4;
        return quarter == 1 ? 6 : quarter == 2 ? 3 : quarter == 3 ? 8 : 1;
    }
    return 1;
}

int digup_video_keyframes(const char *path, double every, int max_pixel, int max_frames, const char *folder,
                          DigupMediaPiece **out_pieces, int *out_count, double *out_duration, int *out_has_audio) {
    *out_pieces = NULL;
    *out_count = 0;
    *out_duration = 0;
    *out_has_audio = 0;
    AVFormatContext *format = NULL;
    if (avformat_open_input(&format, path, NULL, NULL) != 0) return -1;
    if (avformat_find_stream_info(format, NULL) < 0) {
        avformat_close_input(&format);
        return -1;
    }
    const int video_index = stream_of_type(format, AVMEDIA_TYPE_VIDEO);
    *out_has_audio = stream_of_type(format, AVMEDIA_TYPE_AUDIO) >= 0;
    double duration = format->duration != AV_NOPTS_VALUE ? (double)format->duration / AV_TIME_BASE : 0;
    if (video_index < 0 || !(duration > 0)) {
        avformat_close_input(&format);
        *out_duration = duration;
        return 0;
    }
    AVCodecContext *decoder = open_decoder(format->streams[video_index]);
    if (!decoder) {
        avformat_close_input(&format);
        return -1;
    }
    const int orientation = display_orientation(format->streams[video_index]->codecpar);
    const double step = every > duration / max_frames ? every : duration / max_frames;
    PieceList pieces = {0};
    uint64_t last_hash = 0;
    struct SwsContext *hash_sws = NULL, *scale_sws = NULL;
    AVPacket *packet = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    double previous_time = 0;

    for (double time = fmin(0.5, duration / 2); time < duration; time += step) {
        av_seek_frame(format, -1, (int64_t)(time * AV_TIME_BASE), AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(decoder);
        AVFrame *taken = NULL;
        double frame_time = 0;
        // The frame at (or just past) the moment asked for, with half a step's tolerance as the Mac allows
        while (av_read_frame(format, packet) >= 0) {
            const int is_video = packet->stream_index == video_index;
            int sent = is_video ? avcodec_send_packet(decoder, packet) : 0;
            av_packet_unref(packet);
            if (is_video && sent < 0) break;
            while (!taken && is_video && avcodec_receive_frame(decoder, frame) >= 0) {
                const double when = frame->pts != AV_NOPTS_VALUE
                    ? frame->pts * av_q2d(format->streams[video_index]->time_base) : previous_time;
                if (when >= time - step / 2) {
                    taken = av_frame_clone(frame);
                    frame_time = when;
                }
                av_frame_unref(frame);
            }
            if (taken) break;
        }
        if (!taken) continue;
        previous_time = frame_time;
        const uint64_t hash = average_hash(taken, &hash_sws);
        if (pieces.count > 0) {
            const int differing = __builtin_popcountll(hash ^ last_hash);
            if (differing <= 4) {
                av_frame_free(&taken);
                continue;
            }
        }
        last_hash = hash;

        // A JPEG of the frame, turned the way the video says, at most max_pixel on its longest side
        const int source_w = taken->width, source_h = taken->height;
        const double scale = (source_w > max_pixel || source_h > max_pixel)
            ? (double)max_pixel / (source_w > source_h ? source_w : source_h) : 1.0;
        const int target_w = (int)(source_w * scale), target_h = (int)(source_h * scale);
        if (scale_sws) sws_freeContext(scale_sws);
        scale_sws = sws_getContext(source_w, source_h, taken->format, target_w, target_h,
                                   AV_PIX_FMT_RGB24, SWS_BILINEAR, NULL, NULL, NULL);
        uint8_t *rgb = scale_sws ? malloc((size_t)target_w * target_h * 3) : NULL;
        if (rgb) {
            uint8_t *targets[4] = { rgb, NULL, NULL, NULL };
            int target_strides[4] = { target_w * 3, 0, 0, 0 };
            sws_scale(scale_sws, (const uint8_t *const *)taken->data, taken->linesize, 0, source_h,
                      targets, target_strides);
        }
        av_frame_free(&taken);
        int written_width = target_w, written_height = target_h;
        if (rgb && (orientation == 3 || orientation == 6 || orientation == 8)) {
            int w = 0, h = 0;
            uint8_t *turned = rotated(rgb, target_w, target_h, orientation, &w, &h);
            free(rgb);
            rgb = turned;
            written_width = w;
            written_height = h;
        }
        if (rgb) {
            char *name = scratch_name(folder, "jpg");
            if (name && digup_write_jpeg(name, rgb, written_width, written_height, 90) == 0) {
                pieces_add(&pieces, name, frame_time > 0 ? frame_time : 0, duration);
            } else {
                free(name);
            }
            free(rgb);
        }
    }
    // Each kept frame stands for the stretch until the next kept frame
    for (int i = 0; i + 1 < pieces.count; i++) pieces.items[i].end = pieces.items[i + 1].start;

    if (scale_sws) sws_freeContext(scale_sws);
    if (hash_sws) sws_freeContext(hash_sws);
    av_frame_free(&frame);
    av_packet_free(&packet);
    avcodec_free_context(&decoder);
    avformat_close_input(&format);
    *out_pieces = pieces.items;
    *out_count = pieces.count;
    *out_duration = duration;
    return 0;
}

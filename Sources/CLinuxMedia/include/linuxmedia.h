// The Linux readers' C side: ffmpeg decodes and resizes, libexif says when the camera took it, stb_image_write
// writes the scratch copy, tesseract reads the words on a screenshot (what Vision does on the Mac). Small
// functions, one header; the Swift side (LinuxImages.swift) stays free of ffmpeg's pointer choreography.

#ifndef DIGUP_LINUX_MEDIA_H
#define DIGUP_LINUX_MEDIA_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// The image's dimensions, from its header only (nothing decoded). 0 on success, -1 when it can't be read.
int digup_image_dimensions(const char *path, int *width, int *height);

// Decodes an image to RGB24, at most `max_pixel` on its longest side (never upscaled), EXIF orientation
// applied as macOS's thumbnails are. `out_pixels` is one malloc'd width×height×3 buffer; the caller frees it.
// 0 on success, -1 when it can't be decoded.
int digup_decode_image(const char *path, int max_pixel, uint8_t **out_pixels, int *width, int *height);

// The same, for HEIC and AVIF (a phone's photos), which ffmpeg can't be relied on to read: libheif decodes,
// with the orientation its metadata says. 0 on success, -1 when it can't be decoded.
int digup_decode_heif(const char *path, int max_pixel, uint8_t **out_pixels, int *width, int *height);

// The HEIC or AVIF image's dimensions, from its handle (nothing decoded). 0 on success, -1 when it can't be read.
int digup_heif_dimensions(const char *path, int *width, int *height);

// EXIF DateTimeOriginal as the camera wrote it ("2024:05:01 10:12:13"). 0 on success, -1 when there is none.
int digup_exif_taken(const char *path, char *out, int out_size);

// Writes RGB24 out as a JPEG (`quality` 1–100) or a PNG. 0 on success.
int digup_write_jpeg(const char *path, const uint8_t *rgb, int width, int height, int quality);
int digup_write_png(const char *path, const uint8_t *rgb, int width, int height);

// The words tesseract reads in an RGB24 image. `out_text` is one malloc'd UTF-8 string; the caller frees it.
// -1 when tesseract's data isn't installed (no words are read, as Vision reads none in a language it lacks).
int digup_ocr(const uint8_t *rgb, int width, int height, char **out_text);

// MARK: audio and video

/// One window of sound (or one keyframe): a file written into the scratch folder, and when it plays.
/// `path` is malloc'd; free the whole array with `digup_free_pieces`.
typedef struct {
    char *path;
    double start;
    double end;
} DigupMediaPiece;

void digup_free_pieces(DigupMediaPiece *pieces, int count);

/// Audio decoded to 16 kHz mono, cut into `window`-second WAV pieces every `hop` seconds (streaming: one window
/// in memory whatever the length), silence at −50 dBFS or quieter skipped, and a tail beyond the last window's
/// overlap kept when it holds `minimum` seconds or more (as the Mac's reader cuts them). A file with no audio
/// track succeeds with no pieces; -1 only when it can't be read at all.
int digup_audio_windows(const char *path, double window, double hop, double minimum, const char *folder,
                         DigupMediaPiece **out_pieces, int *out_count, double *out_duration);

/// A video's keyframes: one sampled every `interval` seconds (at most `duration` / `max_frames` apart to bound
/// the count), each compared with the last kept one by an 8×8 average hash — within 4 bits only extends it, as
/// the Mac's reader dedups shots — written as JPEGs at most `max_pixel` on their longest side, turned the way
/// the video's rotation says. A file with no video track succeeds with no pieces.
int digup_video_keyframes(const char *path, double every, int max_pixel, int max_frames, const char *folder,
                          DigupMediaPiece **out_pieces, int *out_count, double *out_duration, int *out_has_audio);

// MARK: PDFs (pdfium, in Vendor/pdfium)

/// An open pdfium document. Freed with `digup_pdf_close`.
typedef struct DigupPdfDoc DigupPdfDoc;

/// Opens a PDF. `out_status`: 0 read, 1 password-protected, 2 unreadable (NULL comes back with either).
DigupPdfDoc *digup_pdf_open(const char *path, int *out_status);

/// The document's page count.
int digup_pdf_count(DigupPdfDoc *doc);

/// A page's text layer, as malloc'd UTF-16 (the caller frees); empty when the page has none (a scan).
int digup_pdf_text(DigupPdfDoc *doc, int index, unsigned short **out_text, int *out_length);

/// The document's title from its metadata, as malloc'd UTF-16 (the caller frees); empty when there is none.
int digup_pdf_title(DigupPdfDoc *doc, unsigned short **out_title, int *out_length);

/// Renders a page fitted into a square of `pixels` as a PNG at `out_path`. 0 on success.
int digup_pdf_render(DigupPdfDoc *doc, int index, int pixels, const char *out_path);

void digup_pdf_close(DigupPdfDoc *doc);

#ifdef __cplusplus
}
#endif
#endif

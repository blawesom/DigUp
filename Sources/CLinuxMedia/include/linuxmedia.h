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

// EXIF DateTimeOriginal as the camera wrote it ("2024:05:01 10:12:13"). 0 on success, -1 when there is none.
int digup_exif_taken(const char *path, char *out, int out_size);

// Writes RGB24 out as a JPEG (`quality` 1–100) or a PNG. 0 on success.
int digup_write_jpeg(const char *path, const uint8_t *rgb, int width, int height, int quality);
int digup_write_png(const char *path, const uint8_t *rgb, int width, int height);

// The words tesseract reads in an RGB24 image. `out_text` is one malloc'd UTF-8 string; the caller frees it.
// -1 when tesseract's data isn't installed (no words are read, as Vision reads none in a language it lacks).
int digup_ocr(const uint8_t *rgb, int width, int height, char **out_text);

#ifdef __cplusplus
}
#endif
#endif

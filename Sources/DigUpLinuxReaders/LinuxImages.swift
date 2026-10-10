import CLinuxMedia
import DigUpCore
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Images on Linux, behind the same interface the Mac's ImageExtractor fills: ffmpeg decodes (JPEG, PNG, WebP,
/// GIF, BMP, TIFF) and resizes into the model's budget, stb_image_write writes the scratch copy, libexif says
/// when the camera took it, and tesseract reads the words on a screenshot. `CLinuxMedia` is the C side of it.
enum LinuxImages {
    /// A downscaled copy for the model, written into `folder` (PNG for screenshots, JPEG otherwise). The
    /// dimensions are the original's, as the Mac's extractor reports them.
    static func prepare(_ url: URL, maxPixel: Int, minSide: Int, to folder: URL, png: Bool) throws -> ReadImage {
        var width: Int32 = 0, height: Int32 = 0
        guard digup_image_dimensions(url.path, &width, &height) == 0 else {
            throw ExtractError.unreadable("not an image")
        }
        guard max(width, height) >= Int32(minSide) else { throw ExtractError.tooSmall(Int(width), Int(height)) }
        var pixels: UnsafeMutablePointer<UInt8>?
        var scaledWidth: Int32 = 0, scaledHeight: Int32 = 0
        guard digup_decode_image(url.path, Int32(maxPixel), &pixels, &scaledWidth, &scaledHeight) == 0,
              let pixels else {
            throw ExtractError.unreadable("can't decode image")
        }
        defer { free(pixels) }
        let out = folder.appendingPathComponent(UUID().uuidString + (png ? ".png" : ".jpg"))
        let written = png
            ? digup_write_png(out.path, pixels, scaledWidth, scaledHeight)
            : digup_write_jpeg(out.path, pixels, scaledWidth, scaledHeight, 90)
        guard written == 0 else { throw ExtractError.unreadable("can't encode image") }
        var taken: String?
        var takenBuffer = [CChar](repeating: 0, count: 32)
        if digup_exif_taken(url.path, &takenBuffer, 32) == 0 { taken = String(cString: takenBuffer) }
        return ReadImage(path: out.path, width: Int(width), height: Int(height), taken: taken)
    }

    /// The words on screen (a screenshot), read at a high resolution (Vision reads the full-size image too).
    /// Nil when tesseract's data isn't installed, or the file can't be read.
    static func ocr(_ url: URL) -> String? {
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        guard digup_decode_image(url.path, 2000, &pixels, &width, &height) == 0, let pixels else { return nil }
        defer { free(pixels) }
        var text: UnsafeMutablePointer<CChar>?
        guard digup_ocr(pixels, width, height, &text) == 0, let text else { return nil }
        defer { free(text) }
        return String(cString: text)
    }
}

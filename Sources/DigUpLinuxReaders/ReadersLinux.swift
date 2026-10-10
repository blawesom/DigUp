import DigUpCore
import Foundation

extension Readers {
    /// The Linux readers: walking folders, reading documents — txt, md, html, docx and odt — images,
    /// screenshots and their words (ffmpeg, libheif, libexif, stb and tesseract), and audio and video with
    /// their windows and keyframes (ffmpeg, streaming, as the Mac's AVFoundation readers cut them); code
    /// search needs no platform reader at all. PDFs alone wait for pdfium.
    public static let linux = Readers(
        crawl: LinuxCrawler.crawl,
        prepareImage: LinuxImages.prepare,
        ocr: LinuxImages.ocr,
        pdfPages: { _, _, _, _, _ in throw ExtractError.unreadable("PDFs aren't read on Linux yet") },
        documentText: LinuxDocuments.text,
        audioWindows: LinuxMedia.audioWindows,
        videoKeyframes: LinuxMedia.videoKeyframes
    )
}

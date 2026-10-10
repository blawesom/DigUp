import DigUpCore
import Foundation

extension Readers {
    /// The Linux readers, two slices of the port in: walking folders, reading documents — txt, md, html, docx
    /// and odt — and reading images, screenshots and their words (ffmpeg, libexif, stb and tesseract behind
    /// `CLinuxMedia`); code search needs no platform reader at all. PDFs, audio and video read the same way on
    /// every platform but aren't ported yet, so the crawl leaves them out rather than promising what isn't read.
    public static let linux = Readers(
        crawl: LinuxCrawler.crawl,
        prepareImage: LinuxImages.prepare,
        ocr: LinuxImages.ocr,
        pdfPages: { _, _, _, _, _ in throw ExtractError.unreadable("PDFs aren't read on Linux yet") },
        documentText: LinuxDocuments.text,
        audioWindows: { _, _, _, _ in throw ExtractError.unreadable("audio isn't read on Linux yet") },
        videoKeyframes: { _, _, _, _ in throw ExtractError.unreadable("video isn't read on Linux yet") }
    )
}

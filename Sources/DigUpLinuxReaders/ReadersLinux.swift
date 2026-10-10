import DigUpCore
import Foundation

extension Readers {
    /// The Linux readers, slice one of the port: walking folders and reading documents — txt, md, html, docx and
    /// odt — with code search, which needs no platform reader at all. Pictures, PDFs, audio, video and OCR read the
    /// same way on every platform but aren't ported yet (stb/pdfium/ffmpeg/tesseract follow), so the crawl leaves
    /// them out rather than promising what isn't read (`Rules.classify` in LinuxCrawl.swift says which).
    public static let linux = Readers(
        crawl: LinuxCrawler.crawl,
        prepareImage: { _, _, _, _, _ in throw ExtractError.unreadable("images aren't read on Linux yet") },
        ocr: { _ in nil },
        pdfPages: { _, _, _, _, _ in throw ExtractError.unreadable("PDFs aren't read on Linux yet") },
        documentText: LinuxDocuments.text,
        audioWindows: { _, _, _, _ in throw ExtractError.unreadable("audio isn't read on Linux yet") },
        videoKeyframes: { _, _, _, _ in throw ExtractError.unreadable("video isn't read on Linux yet") }
    )
}

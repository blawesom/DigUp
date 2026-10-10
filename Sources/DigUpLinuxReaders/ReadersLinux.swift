import DigUpCore
import Foundation

extension Readers {
    /// The Linux readers: walking folders, reading documents — txt, md, html, docx and odt — images,
    /// screenshots and their words (ffmpeg, libheif, libexif, stb and tesseract), audio and video with
    /// their windows and keyframes (ffmpeg, streaming, as the Mac's AVFoundation readers cut them), and PDFs
    /// (pdfium, prebuilt by scripts/fetch-pdfium.sh); code search needs no platform reader at all.
    public static let linux = Readers(
        crawl: LinuxCrawler.crawl,
        prepareImage: LinuxImages.prepare,
        ocr: LinuxImages.ocr,
        pdfPages: LinuxPDF.pages,
        documentText: LinuxDocuments.text,
        audioWindows: LinuxMedia.audioWindows,
        videoKeyframes: LinuxMedia.videoKeyframes
    )
}

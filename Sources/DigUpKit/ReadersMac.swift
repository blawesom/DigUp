import DigUpCore
import Foundation

extension Readers {
    /// The readers as macOS builds them: the extraction the index has always used — ImageIO, Vision, PDFKit and
    /// AVFoundation — now behind the seam. AVFoundation's async work is bridged to the synchronous interface here,
    /// on one thread (see `runBlocking`).
    public static let macOS = Readers(
        crawl: Crawler.crawl,
        prepareImage: ImageExtractor.prepare,
        ocr: { url in ImageExtractor.fullImage(url).map(OCR.text(in:)) },
        pdfPages: PDFExtractor.pages,
        documentText: DocExtractor.text,
        audioWindows: { url, window, hop, folder in
            try runBlocking { try await AudioExtractor.windows(of: url, window: window, hop: hop, to: folder) }
        },
        videoKeyframes: { url, every, maxPixel, folder in
            try runBlocking { try await VideoExtractor.keyframes(of: url, every: every, maxPixel: maxPixel, to: folder) }
        }
    )
}

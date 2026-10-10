import CLinuxMedia
import DigUpCore
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// PDFs on Linux: pdfium (Chrome's PDF engine, prebuilt into Vendor/pdfium by scripts/fetch-pdfium.sh) reads
/// the pages, and the core `PageTextProblem` decides what to make of them — the same flow as the Mac's PDFKit
/// extractor. One difference: an Arabic text layer that lost letters to a font's ligatures is kept as it is
/// rather than read again by OCR (tesseract's Arabic isn't among the languages tried; when it is, so is this).
enum LinuxPDF {
    static func pages(of url: URL, range: (Int) -> Range<Int>, minText: Int, renderPixels: Int, to folder: URL)
        throws -> (pages: [ReadPage], total: Int, title: String?) {
        var status: Int32 = 0
        guard let doc = digup_pdf_open(url.path, &status) else {
            if status == 1 { throw ExtractError.locked }
            throw ExtractError.unreadable("can't open PDF")
        }
        defer { digup_pdf_close(doc) }
        let total = Int(digup_pdf_count(doc))
        var pages: [ReadPage] = []
        for index in range(total).clamped(to: 0..<max(total, 0)) {
            var wide: UnsafeMutablePointer<UInt16>?
            var length: Int32 = 0
            guard digup_pdf_text(doc, Int32(index), &wide, &length) == 0, let wide else { continue }
            defer { free(wide) }
            var text = String(decoding: UnsafeBufferPointer(start: wide, count: Int(max(length, 0))), as: UTF16.self)
            while text.hasSuffix("\0") { text.removeLast() }   // pdfium's trailing NUL
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            var garbled: String?
            switch PageTextProblem.check(text) {
            case .lostLetters:
                // On the Mac, OCR reads such a page again when it can; tesseract's Arabic isn't tried here yet,
                // so the layer as it is counts when it has enough text, and the page is rendered otherwise.
                if text.count >= minText {
                    pages.append(ReadPage(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            case .glyphOrder:
                // Too garbled to show or match words against, but its words still make a meaning vector beside
                // the rendered page.
                (text, garbled) = ("", text)
            case nil:
                if text.count >= minText {
                    pages.append(ReadPage(number: index + 1, text: text, imagePath: nil))
                    continue
                }
            }
            let out = folder.appendingPathComponent(UUID().uuidString + ".png")
            guard digup_pdf_render(doc, Int32(index), Int32(renderPixels), out.path) == 0 else { continue }
            pages.append(ReadPage(number: index + 1, text: text, imagePath: out.path, garbled: garbled))
        }
        return (pages, total, Self.title(of: doc))
    }

    private static func title(of doc: OpaquePointer?) -> String? {
        var wide: UnsafeMutablePointer<UInt16>?
        var length: Int32 = 0
        guard digup_pdf_title(doc, &wide, &length) == 0, let wide else { return nil }
        defer { free(wide) }
        let text = String(decoding: UnsafeBufferPointer(start: wide, count: Int(max(length, 0))), as: UTF16.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

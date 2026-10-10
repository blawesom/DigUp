@testable import DigUpCore
@testable import DigUpLinuxReaders
import Foundation
import Testing

/// PDFs on Linux, end to end: the fixtures are written as they are (a small but real PDF writer — catalog,
/// pages, Helvetica text and a drawn rectangle, with a correct xref), pdfium reads them back, and the Mac's
/// PDFKit flow decides what each page becomes: real text as text, too little as a rendered picture.
///
/// Serialized: pdfium isn't thread-safe across documents, and Swift Testing runs tests in parallel; the
/// Indexer itself reads PDFs from one thread, so nothing is given up.
@Suite(.serialized) struct LinuxPDFTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// A PDF of `pages`: a page with text laid out in Helvetica, an empty one drawn as a red rectangle (a
    /// scan has no text to read). `title` goes in the document's info.
    private func makePDF(_ pages: [String], title: String? = nil) throws -> URL {
        var objects: [String] = []
        let font = 3 + pages.count * 2
        let info = font + 1
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = (0..<pages.count).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages.count) >>")
        for (index, text) in pages.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(4 + index * 2) 0 R "
                + "/Resources << /Font << /F1 \(font) 0 R >> >> >>")
            let stream: String
            if text.isEmpty {
                stream = "1 0 0 rg 100 500 412 220 re f"   // a picture without words: a scan
            } else {
                var body = "BT /F1 12 Tf 72 720 Td\n"
                for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    if number > 0 { body += "0 -16 Td\n" }
                    let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "(", with: "\\(")
                        .replacingOccurrences(of: ")", with: "\\)")
                    body += "(\(escaped)) Tj\n"
                }
                stream = body + "ET"
            }
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        objects.append("<< /Producer (DigUp test)" + (title.map { " /Title (\($0))" } ?? "") + " >>")

        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer << /Size \(objects.count + 1) /Root 1 0 R /Info \(info) 0 R >>\nstartxref\n\(xref)\n%%EOF"

        let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func textPagesComeAsTextAndScansAsPictures() throws {
        let url = try makePDF([
            "Garden lease agreement\nThe monthly rent is 950 euros, payable before the fifth of each month.",
            "The tenant will give two months written notice before leaving the flat.",
            "",   // a scan: no text, just a rectangle
        ], title: "Garden lease")
        let read = try LinuxPDF.pages(of: url, range: { total in 0..<total }, minText: 40, renderPixels: 1400,
                                      to: folder)
        #expect(read.total == 3)
        #expect(read.title == "Garden lease")
        #expect(read.pages.count == 3)
        // Real text pages
        #expect(read.pages[0].text.contains("monthly rent"))
        #expect(read.pages[0].imagePath == nil)
        #expect(read.pages[1].text.contains("written notice"))
        // Too little text (and scans): the page rendered as a picture
        #expect(read.pages[2].text.isEmpty)
        #expect(read.pages[2].imagePath.map { FileManager.default.fileExists(atPath: $0) } == true)
        #expect(read.pages[0].garbled == nil)

        // A range of pages, as a long PDF is read a step at a time
        let step = try LinuxPDF.pages(of: url, range: { _ in 1..<3 }, minText: 200, renderPixels: 1400, to: folder)
        #expect(step.pages.map(\.number) == [2, 3])
    }

    @Test func pdfsAreIndexedAndSearched() throws {
        let url = try makePDF([
            "Garden lease agreement\nThe monthly rent is 950 euros, payable before the fifth of each month, "
                + "and the charges of electricity, water and gas are paid separately by the tenant, who also "
                + "keeps the small garden at the back in good order through the year.",
            "The tenant will give two months written notice before leaving the flat, and the landlord returns "
                + "the deposit within a month of the keys changing hands, less what repairs cost.",
        ], title: "Garden lease")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), readers: .linux,
                                  makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder])
        #expect(try indexer.run() == ["done": 1])
        let hit = try #require(try Searcher(store: store, loadVectors: false)
            .search("monthly rent 950 euros", queryVector: nil).first)
        #expect(hit.path == url.path)
        #expect(hit.segment == .page)
        #expect(hit.loc == 1)   // the page it's on
    }
}

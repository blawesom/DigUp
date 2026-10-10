import CLibArchive
import DigUpCore
import Foundation
import FoundationXML   // XMLParser lives here on Linux (Foundation has it on macOS)

/// Documents on Linux: txt and md are read as they are, html through the core `DocText.plainText`, and docx/odt —
/// zip files — through libarchive and `XMLParser`, which pulls their prose out with a newline a paragraph. rtf and
/// the old binary .doc wait for a parser (the crawl leaves them out, saying so).
enum LinuxDocuments {
    static func text(of url: URL) throws -> String {
        switch url.pathExtension.lowercased() {
        case "html", "htm": return DocText.plainText(fromHTML: try readText(url))
        case "docx": return try zipEntry(url, "word/document.xml").map { xmlText($0, wordTextOnly: true) } ?? ""
        case "odt": return try zipEntry(url, "content.xml").map { xmlText($0, wordTextOnly: false) } ?? ""
        default: return try readText(url)
        }
    }

    private static func readText(_ url: URL) throws -> String {
        var encoding = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
        return try String(contentsOf: url, encoding: .isoLatin1)
    }

    /// The bytes of one file inside a zip (docx and odt are), or nil when it isn't there.
    private static func zipEntry(_ url: URL, _ wanted: String) throws -> Data? {
        guard let archive = archive_read_new() else { return nil }
        defer { archive_read_free(archive) }
        archive_read_support_format_zip(archive)
        guard archive_read_open_filename(archive, url.path, 65_536) == ARCHIVE_OK else {
            throw ExtractError.unreadable("can't open \(url.lastPathComponent)")
        }
        var entry: OpaquePointer?
        while archive_read_next_header(archive, &entry) == ARCHIVE_OK {
            let name = entry.flatMap { archive_entry_pathname($0).map(String.init(cString:)) } ?? ""
            guard name == wanted else {
                archive_read_data_skip(archive)
                continue
            }
            var data = Data()
            var block: UnsafeRawPointer?
            var size = 0
            var offset: Int64 = 0
            while archive_read_data_block(archive, &block, &size, &offset) == ARCHIVE_OK, let block {
                data.append(block.assumingMemoryBound(to: UInt8.self), count: size)
            }
            return data
        }
        return nil
    }

    /// The prose in the XML docx (text in `w:t`, a `w:p` a paragraph) and odt (text everywhere in `content.xml`,
    /// a `text:p` or `text:h` a paragraph) keep: good enough for search, which is all the styled forms are read for.
    private static func xmlText(_ data: Data, wordTextOnly: Bool) -> String {
        final class Collector: NSObject, XMLParserDelegate {
            var out = ""
            private let wordText: Bool   // docx keeps its text in w:t elements alone
            private var inWordText = false

            init(wordText: Bool) { self.wordText = wordText }

            func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                         qualifiedName qName: String?, attributes: [String: String]) {
                let name = qName ?? elementName
                if wordText, name.hasSuffix(":t") || name == "t" { inWordText = true }
                if name.hasSuffix(":p") || name == "p" || name.hasSuffix(":h") || name == "h" { out += "\n" }
            }

            func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                        qualifiedName qName: String?) {
                let name = qName ?? elementName
                if wordText, name.hasSuffix(":t") || name == "t" { inWordText = false }
            }

            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if !wordText || inWordText { out += string }
            }
        }
        let collector = Collector(wordText: wordTextOnly)
        let parser = XMLParser(data: data)
        parser.delegate = collector
        parser.parse()
        return collector.out
    }
}

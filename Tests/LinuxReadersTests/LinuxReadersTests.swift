@testable import DigUpCore
@testable import DigUpLinuxReaders
import Foundation
import Testing

/// The Linux readers, end to end: the core `Indexer` (sync, read, embed through `FakeEmbedder`, commit) over real
/// files on a real filesystem, then `Searcher` finding them. Slice one covers documents and code; the fixtures
/// here follow the macOS tests' shapes.
@Suite struct LinuxReadersTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func write(_ path: String, _ content: String) throws -> URL {
        let url = folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func documentsAreIndexedAndSearched() throws {
        try write("notes/budget.txt", """
            The quarterly budget review is due on Friday. Marketing spent forty percent of its
            allocation on the autumn campaign, which brought in twice the usual leads.
            """)
        try write("travel/paris.md", """
            # Weekend in Paris

            The Louvre is closed on Tuesdays, so the museums go on the Saturday instead. The
            train from Gare de Lyon leaves at seven in the morning.
            """)
        try write("web/page.html", """
            <html><head><title>Recipe</title><style>body { color: red }</style></head>
            <body><p>Mix the flour and eggs, then add milk slowly to avoid lumps.</p></body></html>
            """)
        for (name, fixture) in [("docs/lease.docx", "lease.docx"), ("docs/meeting.odt", "meeting.odt")] {
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Reference/\(fixture)")
            let destination = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
        }

        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), readers: .linux,
                                   makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder])
        #expect(try indexer.run() == ["done": 5])

        let searcher = try Searcher(store: store, loadVectors: false)
        func paths(_ query: String) throws -> [String] {
            try searcher.search(query, queryVector: nil).map(\.path)
        }
        // Plain text, markdown, html with its script and style stripped
        #expect(try paths("budget review autumn campaign").first?.hasSuffix("notes/budget.txt") == true)
        #expect(try paths("louvre closed tuesday").first?.hasSuffix("travel/paris.md") == true)
        #expect(try paths("flour eggs lumps").first?.hasSuffix("web/page.html") == true)
        // The word processor formats, through libarchive and the XML parser
        #expect(try paths("monthly rent 950 euros").first?.hasSuffix("docs/lease.docx") == true)
        #expect(try paths("tenant written notice").first?.hasSuffix("docs/lease.docx") == true)
        #expect(try paths("launch postponed december payment").first?.hasSuffix("docs/meeting.odt") == true)
        // What the crawl leaves out on Linux today, it says so (rtf) rather than failing
        #expect(try paths("something nowhere written").isEmpty)
    }

    @Test func crawlClassifiesByExtensionAndSkipsWhatItShould() throws {
        try write("kept/note.txt", "text")
        try write("kept/data.json", "{}")           // code or data: skipped unless asked for
        try write("kept/secret.pem", "key")          // never read
        try write("kept/page.rtf", "rtf")            // not read on Linux yet
        try write("skipped.noindex/inner.txt", "x")  // a .noindex folder isn't walked into
        try write("kept/.hidden.txt", "x")           // hidden files aren't walked into
        let report = LinuxCrawler.crawl([folder], options: IndexOptions())
        #expect(report.candidates.map { ($0.path as NSString).lastPathComponent } == ["note.txt"])
        #expect(report.candidates.first?.kind == .doc)
        #expect(report.skipped["code or data file"] == 1)
        #expect(report.skipped["other type"] == 1)   // .pem, as the Mac's type system leaves it too
        #expect(report.skipped["word processor format, not read on Linux yet"] == 1)
        #expect(report.skippedFolders[".noindex folder"] == 1)
    }

    @Test func codeFilesAreIndexedAndSearched() throws {
        try write("project/retry.py", """
            import time

            def retryWithBackoff(call, attempts=5):
                for attempt in range(attempts):
                    try:
                        return call()
                    except Exception:
                        time.sleep(2 ** attempt)
                raise RuntimeError("all attempts failed")
            """)
        try write("project/util.py", "def add(a, b):\n    return a + b\n")
        var options = IndexOptions()
        options.code = true
        let store = try IndexStore(directory: folder.appendingPathComponent("index"),
                                    file: IndexStore.codeFile)
        let indexer = try Indexer(store: store, options: options, readers: .linux,
                                   makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder.appendingPathComponent("project")])
        #expect(try indexer.run() == ["done": 2])
        let hits = try Searcher(store: store).search("retryWithBackoff", queryVector: nil)
        #expect(hits.first?.segment == .lines && hits.first?.focus != nil)
    }
}

/// The same fake the macOS tests use (LongFilesTests): deterministic vectors from the text's hash.
final class FakeEmbedder: Embedder {
    let info = WorkerInfo(model: "fake", revision: "0000000", runtime: "test", dtype: "f32", dim: Vectors.dimension,
                          textOnly: false, loadSeconds: nil)

    static func vector(for text: String) -> [Float] {
        var state = UInt64(5381)
        for byte in text.utf8 { state = state &* 33 &+ UInt64(byte) }
        var values = (0..<Vectors.dimension).map { _ -> Float in
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Float(Int64(bitPattern: state % 2001) - 1000) / 1000
        }
        let norm = values.reduce(0) { $0 + $1 * $1 }.squareRoot()
        values = values.map { $0 / norm }
        return values
    }

    func embedTexts(_ texts: [String]) throws -> [[Float]] {
        texts.map(Self.vector(for:))
    }

    func embedImages(_ paths: [String], budget: Int) throws -> [Embedding] {
        paths.map { Embedding(vector: Self.vector(for: $0), error: nil) }
    }

    func embedAudio(_ paths: [String]) throws -> [Embedding] {
        paths.map { Embedding(vector: Self.vector(for: $0), error: nil) }
    }

    func close() {}
}

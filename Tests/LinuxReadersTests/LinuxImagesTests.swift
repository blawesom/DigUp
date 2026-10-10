import CLinuxMedia
@testable import DigUpCore
@testable import DigUpLinuxReaders
import Foundation
import Testing

/// Images on Linux, end to end: ffmpeg makes the fixtures (a screenshot with words on it, a photo, one too
/// small), then `LinuxImages` prepares them for the model, tesseract reads the screenshot's words (its English
/// and French data are committed with the test), and the Indexer + Searcher close the loop: a search for the
/// exact code on the screen finds the screenshot.
@Suite struct LinuxImagesTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Runs ffmpeg to make a fixture; the test needs one (drawtext needs a font).
    private func ffmpeg(_ arguments: [String], name: String) throws -> URL {
        try makeFFmpegFixture(in: folder, arguments, name: name)
    }

    @Test func imagesArePreparedResizedAndDated() throws {
        let photo = try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=1600x1200:d=1", "-frames:v", "1"], name: "photo.jpg")
        let prepared = try LinuxImages.prepare(photo, maxPixel: 1024, minSide: 256, to: folder, png: false)
        #expect(prepared.width == 1600 && prepared.height == 1200)   // the original's, as on the Mac
        #expect(prepared.path.hasSuffix(".jpg"))
        var width: Int32 = 0, height: Int32 = 0
        #expect(digup_image_dimensions(prepared.path, &width, &height) == 0)
        #expect(width == 1024 && height == 768)                      // fitted into the budget, aspect kept

        // A small image is left out with its size, not failed
        let tiny = try ffmpeg(["-f", "lavfi", "-i", "color=c=red:s=100x80:d=1", "-frames:v", "1"], name: "tiny.png")
        #expect(throws: ExtractError.self) {
            _ = try LinuxImages.prepare(tiny, maxPixel: 1024, minSide: 256, to: folder, png: false)
        }
    }

    @Test func heicPhotosAreDecoded() throws {
        // A phone's format: heif-enc turns the photo into one, and libheif reads it back
        let photo = try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=1280x960:d=1", "-frames:v", "1"], name: "photo.jpg")
        let heic = folder.appendingPathComponent("phone.heic")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/heif-enc")
        process.arguments = ["-q", "80", "-o", heic.path, photo.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "heif-enc failed")

        let prepared = try LinuxImages.prepare(heic, maxPixel: 1024, minSide: 256, to: folder, png: false)
        #expect(prepared.width == 1280 && prepared.height == 960)   // the original's, as on the Mac
        var width: Int32 = 0, height: Int32 = 0
        #expect(digup_image_dimensions(prepared.path, &width, &height) == 0)
        #expect(width == 1024 && height == 768)
    }

    @Test func screenshotsAreReadAndSearched() throws {
        // tesseract's data, committed with the tests (the system may not have it installed)
        let tessdata = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Reference/tessdata").path
        setenv("TESSDATA_PREFIX", tessdata, 1)

        let shot = try ffmpeg(["-f", "lavfi", "-i", "color=c=white:s=1200x400:d=1", "-frames:v", "1", "-vf",
                               "drawtext=fontfile=%FONT%:text='Payment declined 48217':fontcolor=black:"
                               + "fontsize=72:x=60:y=160"],
                              name: "Screenshot payment.png")
        let words = LinuxImages.ocr(shot) ?? ""
        #expect(words.contains("Payment") == true)
        #expect(words.contains("48217") == true)

        // The screenshot and a photo beside it, indexed and found through the words on the screen
        let photo = try ffmpeg(["-f", "lavfi", "-i", "testsrc2=s=640x480:d=1", "-frames:v", "1"], name: "photo.jpg")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), readers: .linux,
                                  makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder])
        #expect(try indexer.run() == ["done": 2])
        let hits = try Searcher(store: store, loadVectors: false).search("48217", queryVector: nil)
        #expect(hits.first?.kind == .screenshot)
        #expect(hits.first?.path.hasSuffix("Screenshot payment.png") == true)
        #expect(try Searcher(store: store, loadVectors: false).search("declined", queryVector: nil).count == 1)
        _ = photo
    }
}

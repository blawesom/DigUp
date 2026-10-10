@testable import DigUpCore
@testable import DigUpLinuxReaders
import Foundation
import Testing

/// Audio and video on Linux, end to end: ffmpeg makes the fixtures (a minute of tone, silence, and a video
/// with a soundtrack), the readers cut them the way the Mac's AVFoundation readers do — windows that overlap
/// and skip silence, keyframes one a shot — and the Indexer puts them in the index with their moments.
@Suite struct LinuxMediaTests {
    let folder: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DigUpTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    @Test func audioIsCutIntoOverlappingWindows() throws {
        let sound = try makeFFmpegFixture(in: folder,
                                          ["-f", "lavfi", "-i", "sine=frequency=440:duration=62",
                                           "-ar", "16000", "-ac", "1"],
                                          name: "speech.wav")
        let (pieces, duration) = try LinuxMedia.audioWindows(sound, window: 30, hop: 25, to: folder)
        #expect((duration - 62).magnitude < 1)
        // A window at 0 and one at 25, then the tail (50 to the end) once it holds more than the overlap
        #expect(pieces.count == 3)
        #expect(pieces.map(\.start) == [0, 25, 50])
        #expect((pieces[0].end - 30).magnitude < 0.1)
        #expect((pieces[2].end - 62).magnitude < 1)
        for piece in pieces { #expect(FileManager.default.fileExists(atPath: piece.path)) }

        // Silence isn't worth a vector: nothing is cut from it
        let silence = try makeFFmpegFixture(in: folder,
                                            ["-f", "lavfi", "-i", "anullsrc=duration=40:channel_layout=mono",
                                             "-ar", "16000"],
                                            name: "silence.wav")
        let (quiet, _) = try LinuxMedia.audioWindows(silence, window: 30, hop: 25, to: folder)
        #expect(quiet.isEmpty)
    }

    @Test func videosAreSampledIntoKeyframes() throws {
        let video = try makeFFmpegFixture(in: folder,
                                          ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=10:duration=18",
                                           "-f", "lavfi", "-i", "sine=frequency=440:duration=18",
                                           "-shortest"],
                                          name: "clip.mp4")
        let (frames, duration, hasAudio) = try LinuxMedia.videoKeyframes(video, every: 3, maxPixel: 1024, to: folder)
        #expect((duration - 18).magnitude < 1)
        #expect(hasAudio == true)
        #expect(frames.count >= 4 && frames.count <= 7)   // one every 3 s, near-duplicates folded together
        for frame in frames {
            #expect(FileManager.default.fileExists(atPath: frame.path))
            if frames.last.map({ $0.path != frame.path }) == true {
                #expect(frame.end > frame.start)
            }
        }
        // Each kept frame stands for the stretch until the next kept one
        for index in frames.indices.dropLast() {
            #expect((frames[index].end - frames[index + 1].start).magnitude < 0.01)
        }
    }

    @Test func audioAndVideoAreIndexedWithTheirMoments() throws {
        try makeFFmpegFixture(in: folder,
                              ["-f", "lavfi", "-i", "sine=frequency=440:duration=62", "-ar", "16000", "-ac", "1"],
                              name: "recording.wav")
        try makeFFmpegFixture(in: folder,
                              ["-f", "lavfi", "-i", "testsrc2=size=640x360:rate=10:duration=12",
                               "-f", "lavfi", "-i", "sine=frequency=440:duration=12", "-shortest"],
                              name: "clip.mp4")
        let store = try IndexStore(directory: folder.appendingPathComponent("index"))
        let indexer = try Indexer(store: store, options: IndexOptions(), readers: .linux,
                                  makeEmbedder: { FakeEmbedder() })
        _ = try indexer.sync([folder])
        #expect(try indexer.run() == ["done": 2])
        var audioWindows = 0, frames = 0
        try store.db.query("SELECT kind FROM segments WHERE kind IN ('audio', 'frame')") { row in
            if row.text(0) == "audio" { audioWindows += 1 } else { frames += 1 }
        }
        // 3 of the recording, and the clip's soundtrack as one short window (12 s under a 30 s window)
        #expect(audioWindows == 4)
        #expect(frames >= 2)   // one a shot: what testsrc2's steady pattern leaves after the dedup
        let hit = try Searcher(store: store, loadVectors: false).search("440", queryVector: nil)
        _ = hit   // audio has no words; meaning comes with the model
    }
}

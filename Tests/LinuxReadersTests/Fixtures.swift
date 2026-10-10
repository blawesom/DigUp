import Foundation
import Testing

/// Test fixtures made with ffmpeg: images with words on them, photos, sound, video — the same tool the
/// testbed uses (make-testbed.sh needs it too).
func makeFFmpegFixture(in folder: URL, _ arguments: [String], name: String) throws -> URL {
    let font = ["/usr/share/fonts/TTF/DejaVuSans-Bold.ttf", "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"]
        .first { FileManager.default.fileExists(atPath: $0) }
    var full = arguments
    if let font, let index = full.firstIndex(of: "%FONT%") { full[index] = font }
    let out = folder.appendingPathComponent(name)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ffmpeg")
    process.arguments = ["-loglevel", "error", "-y"] + full + [out.path]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0, "ffmpeg failed for \(name)")
    return out
}

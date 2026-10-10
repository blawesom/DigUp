import CLinuxMedia
import DigUpCore
import Foundation

#if canImport(Glibc)
import Glibc
#endif

/// Audio and video on Linux, behind the interface the Mac's AVFoundation extractors fill. The C side
/// (`CLinuxMedia`) decodes and streams; this converts what it wrote into `MediaPiece`s and frees what C
/// allocated.
enum LinuxMedia {
    /// The pieces C allocated, as the index keeps them.
    private static func pieces(_ raw: UnsafeMutablePointer<DigupMediaPiece>?, _ count: Int32) -> [MediaPiece] {
        guard let raw, count > 0 else { return [] }
        var out: [MediaPiece] = []
        out.reserveCapacity(Int(count))
        for index in 0..<Int(count) {
            let piece = raw[index]
            if let path = piece.path {
                out.append(MediaPiece(path: String(cString: path), start: piece.start, end: piece.end))
            }
        }
        digup_free_pieces(raw, count)
        return out
    }

    /// Audio cut into 16 kHz mono windows (`window` seconds every `hop`), silence skipped, the tail kept when
    /// it holds something new: the way the Mac's reader cuts it.
    static func audioWindows(_ url: URL, window: Double, hop: Double, to folder: URL) throws
        -> (pieces: [MediaPiece], duration: Double) {
        var raw: UnsafeMutablePointer<DigupMediaPiece>?
        var count: Int32 = 0
        var duration = 0.0
        guard digup_audio_windows(url.path, window, hop, 2.0, folder.path, &raw, &count, &duration) == 0 else {
            throw ExtractError.unreadable("can't read audio")
        }
        return (pieces(raw, count), duration)
    }

    /// A video's keyframes (one a shot, at most `every` seconds apart) and whether it has a soundtrack.
    static func videoKeyframes(_ url: URL, every: Double, maxPixel: Int, to folder: URL) throws
        -> (frames: [MediaPiece], duration: Double, hasAudio: Bool) {
        var raw: UnsafeMutablePointer<DigupMediaPiece>?
        var count: Int32 = 0
        var duration = 0.0
        var hasAudio: Int32 = 0
        guard digup_video_keyframes(url.path, every, Int32(maxPixel), 1200, folder.path,
                                    &raw, &count, &duration, &hasAudio) == 0 else {
            throw ExtractError.unreadable("can't read video")
        }
        return (pieces(raw, count), duration, hasAudio != 0)
    }
}

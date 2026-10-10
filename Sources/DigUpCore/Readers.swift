import Foundation

/// An image prepared for the vision encoder: downscaled, written to a scratch file (JPEG, or PNG for screenshots),
/// with what indexing learned about the original.
public struct ReadImage: Sendable {
    public let path: String
    public let width: Int
    public let height: Int
    public let taken: String?   // EXIF DateTimeOriginal, as written by the camera

    public init(path: String, width: Int, height: Int, taken: String?) {
        self.path = path
        self.width = width
        self.height = height
        self.taken = taken
    }
}

/// One page of a PDF, as the index keeps it.
public struct ReadPage: Sendable {
    public let number: Int        // 1-based
    public let text: String       // may be empty for scans
    public let imagePath: String? // set when the page had too little text and was rendered for the vision encoder
    public var ocr = false        // the text came from OCR: the text layer was garbled (`PageTextProblem.lostLetters`)
    /// Text read in glyph order (`PageTextProblem.glyphOrder`): too garbled to show or match words against, but
    /// enough of its words survive for a meaning vector beside the page's picture.
    public var garbled: String?

    public init(number: Int, text: String, imagePath: String?, ocr: Bool = false, garbled: String? = nil) {
        self.number = number
        self.text = text
        self.imagePath = imagePath
        self.ocr = ocr
        self.garbled = garbled
    }
}

/// A stretch of audio written to a temporary WAV for the model, or a video frame written to an image file.
public struct MediaPiece: Sendable {
    public let path: String
    public let start: Double
    public var end: Double

    public init(path: String, start: Double, end: Double) {
        self.path = path
        self.start = start
        self.end = end
    }
}

/// What a crawl found: the files to index, and why the rest was left out.
public struct CrawlReport: Sendable {
    public var candidates: [Candidate] = []
    public var skipped: [String: Int] = [:]          // reason → files
    public var skippedFolders: [String: Int] = [:]   // reason → folders not walked into
    public var datasets: [String: Int] = [:]         // folder → files skipped as a dataset

    public init() {}
}

/// How the index reads files, per platform: one member a capability, filled in by the platform — macOS by ImageIO,
/// Vision, PDFKit and AVFoundation (`Readers.macOS`), Linux by stb_image, pdfium, ffmpeg and Tesseract when its
/// readers land. Every member is stateless and thread-safe (`Sendable`): the `Indexer` runs them on its preparation
/// thread, one batch ahead of the model. They touch files only — never the database, never the model — and write
/// their scratch files into the folder they're given.
public struct Readers: Sendable {
    /// The files worth indexing in the chosen folders (the crawler), with why the rest was left out.
    public var crawl: @Sendable ([URL], IndexOptions) -> CrawlReport
    /// An image read, downscaled for the model and written into `folder`. `maxPixel` bounds its longest side,
    /// `minSide` the shortest side of one worth keeping at all; `png` keeps screenshots lossless.
    public var prepareImage: @Sendable (_ url: URL, _ maxPixel: Int, _ minSide: Int, _ to: URL, _ png: Bool) throws -> ReadImage
    /// The words on screen (a screenshot), read from the full-resolution image. Nil where the platform can't.
    public var ocr: @Sendable (_ url: URL) -> String?
    /// The pages of a PDF: `range` picks which (asked for the page count), `minText` is how little text makes a page
    /// worth rendering as a picture instead (at `renderPixels`, written into `folder`).
    public var pdfPages: @Sendable (_ url: URL, _ range: (Int) -> Range<Int>, _ minText: Int, _ renderPixels: Int,
                                    _ to: URL) throws -> (pages: [ReadPage], total: Int, title: String?)
    /// The text of a document (txt, md, html, rtf, docx…).
    public var documentText: @Sendable (_ url: URL) throws -> String
    /// Audio cut into `window`-second WAV pieces every `hop` seconds (a video's soundtrack too), silent stretches
    /// left out, written into `folder`.
    public var audioWindows: @Sendable (_ url: URL, _ window: Double, _ hop: Double, _ to: URL)
        throws -> (pieces: [MediaPiece], duration: Double)
    /// A video's keyframes (one a shot, at most every `interval` seconds, `maxPixel` on a side), and whether it has
    /// a soundtrack, written into `folder`.
    public var videoKeyframes: @Sendable (_ url: URL, _ every: Double, _ maxPixel: Int, _ to: URL)
        throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool)

    public init(crawl: @escaping @Sendable ([URL], IndexOptions) -> CrawlReport,
                prepareImage: @escaping @Sendable (URL, Int, Int, URL, Bool) throws -> ReadImage,
                ocr: @escaping @Sendable (URL) -> String?,
                pdfPages: @escaping @Sendable (URL, (Int) -> Range<Int>, Int, Int, URL) throws -> (pages: [ReadPage], total: Int, title: String?),
                documentText: @escaping @Sendable (URL) throws -> String,
                audioWindows: @escaping @Sendable (URL, Double, Double, URL) throws -> (pieces: [MediaPiece], duration: Double),
                videoKeyframes: @escaping @Sendable (URL, Double, Int, URL) throws -> (frames: [MediaPiece], duration: Double, hasAudio: Bool)) {
        self.crawl = crawl
        self.prepareImage = prepareImage
        self.ocr = ocr
        self.pdfPages = pdfPages
        self.documentText = documentText
        self.audioWindows = audioWindows
        self.videoKeyframes = videoKeyframes
    }
}

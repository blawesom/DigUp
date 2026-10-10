// swift-tools-version: 6.2
import PackageDescription

// The engine's portable core builds everywhere Swift does (macOS and Linux today); the parts that read files with
// Apple's frameworks and the app are macOS-only, while Linux has its own readers (ffmpeg, pdfium, tesseract…) and
// the same `digup` CLI over them.
var products: [Product] = [
    .library(name: "DigUpCore", targets: ["DigUpCore"]),
]
var coreDependencies: [Target.Dependency] = [
    .product(name: "Crypto", package: "swift-crypto"),   // SHA-256 for the model files; CryptoKit behind it on macOS
]
#if os(Linux)
// The SQLite3 module, which Apple toolchains ship and Linux's doesn't provide (the system sqlite, FTS5 included).
coreDependencies.append(.target(name: "CSQLite"))
#endif

var targets: [Target] = [
    // The engine's portable core: the index store and its SQLite database, search (meaning + words), keyword
    // text, the crawl and code rules, code extraction, the embedder interface and worker client, the model files,
    // and the Indexer that orchestrates the readers. No UI, no Apple frameworks.
    .target(name: "DigUpCore", dependencies: coreDependencies),
    .testTarget(name: "DigUpCoreTests", dependencies: ["DigUpCore"]),
]
#if os(Linux)
targets += [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    // The Linux readers (Phase 2): documents (libarchive), images and their words (ffmpeg, libheif, libexif,
    // stb_image_write, tesseract), audio and video windows and keyframes (ffmpeg), PDFs (pdfium, prebuilt into
    // Vendor/pdfium by scripts/fetch-pdfium.sh). The C side is CLinuxMedia.
    .systemLibrary(name: "CLibArchive", path: "Sources/CLibArchive"),
    .target(name: "CLinuxMedia",
            cSettings: [.unsafeFlags(["-I\(Context.packageDirectory)/Vendor/pdfium/include"])],
            linkerSettings: [.unsafeFlags(["-lavformat", "-lavcodec", "-lavutil", "-lswscale", "-lswresample",
                                           "-lheif", "-lexif", "-ltesseract",
                                           "-L\(Context.packageDirectory)/Vendor/pdfium/lib", "-lpdfium",
                                           "-Xlinker", "-rpath", "-Xlinker",
                                           "\(Context.packageDirectory)/Vendor/pdfium/lib"])]),
    .target(name: "DigUpLinuxReaders", dependencies: ["DigUpCore", "CLibArchive", "CLinuxMedia"]),
    .testTarget(name: "LinuxReadersTests", dependencies: ["DigUpLinuxReaders", "CLinuxMedia"],
                resources: [.copy("Reference")]),
    // llama.cpp, the same module as the Mac's but linking the Linux build (scripts/build-llama.sh, CPU).
    .systemLibrary(name: "CLlamaLinux", path: "Sources/CLlamaLinux"),
    .target(name: "LlamaRuntime", dependencies: ["CLlamaLinux", "DigUpCore"],
            linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]),
    // The developer CLI, the same commands over the Linux readers.
    .executableTarget(name: "digup", dependencies: ["DigUpLinuxReaders", "LlamaRuntime"]),
    .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
]
#endif

#if os(macOS)
products += [
    .executable(name: "digup", targets: ["digup"]),
    .executable(name: "DigUpApp", targets: ["DigUpApp"]),
    .library(name: "DigUpKit", targets: ["DigUpKit"]),
]
targets += [
    // The Mac's readers: the crawler, the extractors (Apple frameworks) and the estimates, which re-export
    // DigUpCore, so `import DigUpKit` sees both, as it always did.
    .target(name: "DigUpKit", dependencies: ["DigUpCore"]),
    // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama, Metal) and EmbeddingGemma 2 on it.
    .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
    .target(name: "LlamaRuntime", dependencies: ["CLlama", "DigUpCore"],
            linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]),
    // Developer CLI: estimate / index / search / status / eval. Doubles as the eval harness, and the app runs it as
    // its indexing helper and its query encoder.
    .executableTarget(name: "digup", dependencies: ["DigUpKit", "LlamaRuntime"]),
    // The menubar + hotkey app. build.sh wraps it into build.noindex/DigUp.app. (The product can't be called
    // "DigUp": on a case-insensitive disk it would collide with the `digup` CLI binary.)
    .executableTarget(
        name: "DigUpApp",
        dependencies: ["DigUpKit", .product(name: "Sparkle", package: "Sparkle")],
        swiftSettings: [.defaultIsolation(MainActor.self)],
        linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
    ),
    .testTarget(name: "DigUpKitTests", dependencies: ["DigUpKit"]),
    .testTarget(name: "LlamaRuntimeTests", dependencies: ["LlamaRuntime"]),
]
#endif

var packageDependencies: [PackageDescription.Package.Dependency] = []
#if os(macOS)
packageDependencies.append(
    // In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it. Linux
    // doesn't declare it: SwiftPM would download and validate the binary archive there anyway.
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
)
#endif
packageDependencies.append(
    // SHA-256 (CryptoKit behind it on macOS), for the model files.
    .package(url: "https://github.com/apple/swift-crypto", from: "3.0.0")
)

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: packageDependencies,
    targets: targets
)

// swift-tools-version: 6.2
import PackageDescription

// The engine's portable core builds everywhere Swift does (macOS and Linux today); the parts that read files with
// Apple's frameworks, the model runtime and the app are macOS-only. (Phase 1 of the port; the readers follow.)
var products: [Product] = [
    .library(name: "DigUpCore", targets: ["DigUpCore"]),
]
var coreDependencies: [Target.Dependency] = []
#if os(Linux)
// The SQLite3 module (Apple toolchains ship one; Linux's comes from the system sqlite, FTS5 included).
coreDependencies.append(.target(name: "CSQLite"))
#endif

var targets: [Target] = [
    // The engine's portable core: the index store and its SQLite database, search (meaning + words), keyword
    // text, the crawl and code rules, code extraction, the embedder interface and worker client. No UI, no Apple
    // frameworks — on Linux this is what builds and tests.
    .target(name: "DigUpCore", dependencies: coreDependencies),
    .testTarget(name: "DigUpCoreTests", dependencies: ["DigUpCore"]),
]
#if os(Linux)
targets += [
    // The SQLite3 module (Apple toolchains ship one; Linux's comes from the system sqlite, FTS5 included).
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
    // The Linux readers (Phase 2): walking and reading documents (libarchive), images and their words (ffmpeg,
    // libexif, stb_image_write, tesseract — the C side in CLinuxMedia), with the rest of `Readers.linux` to follow.
    .systemLibrary(name: "CLibArchive", path: "Sources/CLibArchive"),
    .target(name: "CLinuxMedia",
            linkerSettings: [.unsafeFlags(["-lavformat", "-lavcodec", "-lavutil", "-lswscale",
                                           "-lexif", "-ltesseract"])]),
    .target(name: "DigUpLinuxReaders", dependencies: ["DigUpCore", "CLibArchive", "CLinuxMedia"]),
    .testTarget(name: "LinuxReadersTests", dependencies: ["DigUpLinuxReaders", "CLinuxMedia"]),
]
#endif

#if os(macOS)
products += [
    .executable(name: "digup", targets: ["digup"]),
    .executable(name: "DigUpApp", targets: ["DigUpApp"]),
    .library(name: "DigUpKit", targets: ["DigUpKit"]),
]
targets += [
    // The platform side of the engine: the crawler, the extractors (Apple frameworks) and the indexer that
    // orchestrates them, plus the model files. Re-exports DigUpCore, so `import DigUpKit` sees both, as before.
    .target(name: "DigUpKit", dependencies: ["DigUpCore"]),
    // llama.cpp (scripts/build-llama.sh builds it into Vendor/llama) and EmbeddingGemma 2 on it.
    .systemLibrary(name: "CLlama", path: "Sources/CLlama"),
    .target(
        name: "LlamaRuntime",
        dependencies: ["CLlama", "DigUpKit"],
        linkerSettings: [.unsafeFlags(["-L\(Context.packageDirectory)/Vendor/llama/lib"])]
    ),
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

let package = Package(
    name: "DigUp",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [
        // In-app updates (the app only). build.sh embeds the framework in Contents/Frameworks and signs it.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: targets
)

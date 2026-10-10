// DigUpKit: the platform side of the engine — reading files (images, PDFs, documents, audio, video) with Apple's
// frameworks (`Readers.macOS`), the crawler that walks the folders, indexing estimates and the model files. The
// portable core (the index, the search, the keyword text, code extraction and the `Indexer` that orchestrates the
// readers) is DigUpCore, which this module builds on and re-exports, so `import DigUpKit` sees both, as it did
// before the split.
@_exported import DigUpCore

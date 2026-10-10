// DigUpKit: the platform side of the engine — reading files (images, PDFs, documents, audio, video) with Apple's
// frameworks, the crawler that walks the folders, and the Indexer that orchestrates it all. The portable core
// (the index, the search, the keyword text, code extraction) is DigUpCore, which this module builds on and
// re-exports, so `import DigUpKit` sees both, as it did before the split.
@_exported import DigUpCore

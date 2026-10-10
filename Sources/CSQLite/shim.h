// The SQLite3 module, which Apple's toolchains provide and Linux's don't: this shim points at the system
// sqlite's header (with FTS5, as macOS's has). Only built on Linux (Package.swift).
#include <sqlite3.h>

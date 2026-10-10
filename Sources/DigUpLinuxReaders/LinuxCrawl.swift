import DigUpCore
import Foundation

#if canImport(Glibc)
import Glibc
#endif

extension Rules {
    /// What the main index does with a file on Linux: by extension and name alone, for there's no UTType hierarchy
    /// to ask, and no iCloud to stay out of. Documents and code are read today (slice one of the Linux readers);
    /// pictures, audio, video and PDFs are ignored — not failed — until their readers land.
    static func classify(_ url: URL, options: IndexOptions) -> Classification {
        let ext = url.pathExtension.lowercased()
        if options.excludedExtensions.contains(ext) { return .skip("excluded type") }
        // .ts / .mts are usually TypeScript, which Spotlight calls MPEG-2 video. Only a real transport stream is video.
        if ext == "ts" || ext == "mts" || ext == "m2ts" {
            if isMPEGTransportStream(url) { return .index(.video) }
            return options.includeCode ? .index(.doc) : .skip("code or data file")
        }
        if docExtensions.contains(ext) {
            // rtf and the old binary .doc need a parser Linux doesn't have yet (the Cocoa text system reads them
            // on the Mac).
            if ext == "rtf" || ext == "doc" { return .skip("word processor format, not read on Linux yet") }
            return .index(.doc)
        }
        if codeExtensions.contains(ext) { return options.includeCode ? .index(.doc) : .skip("code or data file") }
        return .ignore
    }
}

/// The Linux walk: a port of DigUpKit's Crawler, which it stays in step with, with the differences the platform
/// makes — files are classified by extension (no UTType), there's no iCloud to stay out of and no dataless
/// placeholders to avoid downloading, and `git` is where Linux puts it.
enum LinuxCrawler {
    static func crawl(_ roots: [URL], options: IndexOptions) -> CrawlReport {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        // corelibs-foundation reports every directory as a package on Linux (isPackage is true for folders), so
        // the walk doesn't ask: every directory is a directory (Linux has no .app bundles to keep out).
        let keys: [URLResourceKey] = [.isDirectoryKey]
        var report = CrawlReport()
        var projectRoots = Set<String>()
        var repos = GitRepos()
        var found: [Candidate] = []
        var foundPaths = Set<String>()   // a folder inside another root would be walked twice
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })

        for root in roots.map({ $0.standardizedFileURL }) {
            if options.code {
                repos.enterRoot(root.path)
            } else if Rules.isProjectRoot(root.path) {
                projectRoots.insert(root.path)
            }
            // A skip applies inside the chosen folders that contain it: a folder chosen inside a skipped one is
            // walked whole (`FolderSelection`).
            let real = FolderSelection.realPath(root.path)
            let skips = options.excludedFolders.filter {
                FolderSelection.isInside($0, root.path) || FolderSelection.isInside($0, real)
            }.flatMap { [$0, FolderSelection.realPath($0)] }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles],
                                             errorHandler: { _, _ in true }) else { continue }
            func visit(_ url: URL) {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if let reason = Rules.skipReason(forFolder: url, home: home, excluded: skips)
                        ?? (options.code ? Rules.codeSkipReason(forFolder: url) : nil) {
                        walker.skipDescendants()
                        report.skippedFolders[reason, default: 0] += 1
                    } else if options.code {
                        repos.enter(url.path)
                    } else if Rules.isProjectRoot(url.path) {
                        projectRoots.insert(url.path)
                    }
                    return
                }
                let classification = options.code ? Rules.classifyCode(url, options: options)
                    : Rules.classify(url, options: options)
                switch classification {
                case .ignore:
                    report.skipped["other type", default: 0] += 1
                case .skip(let reason):
                    report.skipped[reason, default: 0] += 1
                case .index(let kind):
                    var info = stat()
                    guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
                        report.skipped["link or special file", default: 0] += 1
                        return
                    }
                    if options.code {
                        // Too big to be written by hand; a notebook's file holds its outputs too.
                        let limit = url.pathExtension.lowercased() == "ipynb" ? options.maxNotebookBytes
                            : options.maxCodeBytes
                        if info.st_size > limit {
                            report.skipped["too big to be written by hand", default: 0] += 1
                            return
                        }
                        if repos.ignores(url.path) {
                            report.skipped["ignored by git", default: 0] += 1
                            return
                        }
                    }
                    guard foundPaths.insert(url.path).inserted else { return }
                    let mtime = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
                    found.append(Candidate(path: url.path, kind: kind, size: Int64(info.st_size), mtime: mtime,
                                            inode: UInt64(info.st_ino),
                                            device: UInt64(bitPattern: Int64(info.st_dev))))
                }
            }

            while let url = walker.nextObject() as? URL {
                visit(url)
            }
        }

        // Inside a code project only screenshots count (assets, fixtures and datasets don't).
        var inProject: [String: Bool] = [:]
        func isInProject(_ folder: String) -> Bool {
            if let known = inProject[folder] { return known }
            let parent = (folder as NSString).deletingLastPathComponent
            let answer = projectRoots.contains(folder) || (parent != folder && parent.count > 1 && isInProject(parent))
            inProject[folder] = answer
            return answer
        }
        var kept: [Candidate] = []
        for file in found {
            if !options.code, file.kind != .screenshot, isInProject((file.path as NSString).deletingLastPathComponent) {
                report.skipped["inside a code project", default: 0] += 1
            } else {
                kept.append(file)
            }
        }

        if !options.includeDatasets, !options.code {
            let datasets = Rules.datasetFolders(kept.map {
                (($0.path as NSString).deletingLastPathComponent,
                 (($0.path as NSString).lastPathComponent as NSString).deletingPathExtension, $0.kind)
            }, roots: rootPaths)
            if !datasets.isEmpty {
                report.datasets = datasets
                kept.removeAll { file in
                    let skip = datasets[(file.path as NSString).deletingLastPathComponent] != nil
                        && [.image, .audio, .video].contains(file.kind)
                    if skip { report.skipped["dataset", default: 0] += 1 }
                    return skip
                }
            }
        }
        report.candidates = kept
        return report
    }
}

/// The git repos a code crawl walks through, and the files each keeps: a port of DigUpKit's, with Linux's git paths.
struct GitRepos {
    private var files: [String: Set<String>?] = [:]
    private var repoOf: [String: String?] = [:]

    mutating func enterRoot(_ path: String) {
        var folder = path
        while true {
            if FileManager.default.fileExists(atPath: folder + "/.git") {
                files[folder] = GitFiles.list(folder)
                repoOf[path] = folder
                return
            }
            let parent = (folder as NSString).deletingLastPathComponent
            guard parent != folder, parent.count > 1 else { break }
            folder = parent
        }
        repoOf[path] = .some(nil)
    }

    mutating func enter(_ path: String) {
        var isFolder: ObjCBool = false
        if FileManager.default.fileExists(atPath: path + "/.git", isDirectory: &isFolder), isFolder.boolValue {
            files[path] = GitFiles.list(path)
            repoOf[path] = path
        }
    }

    private mutating func repo(of folder: String) -> String? {
        if let known = repoOf[folder] { return known }
        let parent = (folder as NSString).deletingLastPathComponent
        let answer = parent != folder && parent.count > 1 ? repo(of: parent) : nil
        repoOf[folder] = answer
        return answer
    }

    mutating func ignores(_ path: String) -> Bool {
        guard let repo = repo(of: (path as NSString).deletingLastPathComponent), let kept = files[repo] ?? nil
        else { return false }
        return !kept.contains(String(path.dropFirst(repo.count + 1)))
    }
}

/// The files git keeps in a repo: tracked ones, and new ones its .gitignore doesn't leave out.
enum GitFiles {
    static let git: String? = ["/usr/bin/git", "/usr/local/bin/git", "/opt/homebrew/bin/git"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Paths relative to `repo`, or nil when git can't say (no git, not a repo, an error).
    static func list(_ repo: String) -> Set<String>? {
        guard let git else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", repo, "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
        // Reading only: never wait for, or take, the repo's lock (an editor's git may be busy in it).
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return Set(data.split(separator: 0).compactMap { String(data: Data($0), encoding: .utf8) })
    }
}

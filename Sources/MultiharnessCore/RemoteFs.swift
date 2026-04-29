import Foundation

public struct FsEntry: Sendable, Equatable {
    public let name: String
    public let path: String
    public let isGitRepo: Bool

    public init(name: String, path: String, isGitRepo: Bool) {
        self.name = name
        self.path = path
        self.isGitRepo = isGitRepo
    }
}

public struct FsListing: Sendable, Equatable {
    public let path: String
    public let parent: String?
    public let entries: [FsEntry]

    public init(path: String, parent: String?, entries: [FsEntry]) {
        self.path = path
        self.parent = parent
        self.entries = entries
    }
}

public enum RemoteFs {

    public enum ListError: Error, LocalizedError {
        case notADirectory(String)
        case underlying(String)

        public var errorDescription: String? {
            switch self {
            case .notADirectory(let p): return "path does not exist or is not a directory: \(p)"
            case .underlying(let m): return m
            }
        }
    }

    /// List the immediate subdirectories of `path`. Hidden (dot-prefixed)
    /// entries and regular files are filtered out. `isGitRepo` is true when
    /// the entry contains a `.git` (file or directory — worktrees use a file).
    public static func list(path: String) throws -> FsListing {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw ListError.notADirectory(path)
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let canonicalPath = url.path

        let raw: [URL]
        do {
            raw = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ListError.underlying((error as NSError).localizedDescription)
        }

        var entries: [FsEntry] = []
        entries.reserveCapacity(raw.count)
        for entry in raw {
            let entryIsDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard entryIsDir else { continue }
            let gitPath = entry.appendingPathComponent(".git").path
            let isGitRepo = fm.fileExists(atPath: gitPath)
            entries.append(FsEntry(
                name: entry.lastPathComponent,
                path: entry.standardizedFileURL.path,
                isGitRepo: isGitRepo
            ))
        }
        entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let parent: String?
        if canonicalPath == "/" {
            parent = nil
        } else {
            parent = url.deletingLastPathComponent().standardizedFileURL.path
        }
        return FsListing(path: canonicalPath, parent: parent, entries: entries)
    }
}

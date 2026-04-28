import Foundation

public struct WorktreeStatus: Sendable, Equatable {
    public var modifiedFiles: [String]
    public var untrackedFiles: [String]
    public var diffStatVsBase: String
}

public struct WorktreeService: Sendable {
    public init() {}

    public var rootDir: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent("multiharness").appendingPathComponent("workspaces", isDirectory: true)
    }

    public func worktreePath(projectSlug: String, workspaceSlug: String) -> URL {
        rootDir
            .appendingPathComponent(projectSlug, isDirectory: true)
            .appendingPathComponent(workspaceSlug, isDirectory: true)
    }

    public func createWorktree(
        repoPath: String,
        baseBranch: String,
        branchName: String,
        worktreePath: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: worktreePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Best-effort fetch; ignore errors (offline, no remote).
        _ = try? runGit(at: repoPath, args: ["fetch", "origin"])
        _ = try runGit(at: repoPath, args: [
            "worktree", "add", "-b", branchName, worktreePath.path, baseBranch,
        ])
    }

    public func removeWorktree(repoPath: String, worktreePath: String, force: Bool = false) throws {
        var args = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(worktreePath)
        _ = try runGit(at: repoPath, args: args)
    }

    public func listBranches(repoPath: String) throws -> [String] {
        let out = try runGit(at: repoPath, args: ["branch", "--format=%(refname:short)"])
        return out.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public func currentBranch(repoPath: String) throws -> String {
        try runGit(at: repoPath, args: ["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func status(worktreePath: String, baseBranch: String) throws -> WorktreeStatus {
        let porcelain = try runGit(at: worktreePath, args: ["status", "--porcelain"])
        var modified: [String] = []
        var untracked: [String] = []
        for line in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            guard raw.count > 3 else { continue }
            let code = String(raw.prefix(2))
            let path = String(raw.dropFirst(3))
            if code == "??" {
                untracked.append(path)
            } else {
                modified.append(path)
            }
        }
        let diffStat: String
        do {
            diffStat = try runGit(
                at: worktreePath,
                args: ["diff", "--stat", "\(baseBranch)...HEAD"]
            )
        } catch {
            diffStat = ""
        }
        return WorktreeStatus(
            modifiedFiles: modified,
            untrackedFiles: untracked,
            diffStatVsBase: diffStat
        )
    }

    public func diff(worktreePath: String, baseBranch: String, file: String? = nil) throws -> String {
        var args = ["diff", "\(baseBranch)...HEAD"]
        if let file { args.append(contentsOf: ["--", file]) }
        return try runGit(at: worktreePath, args: args)
    }

    public func runGit(at path: String, args: [String]) throws -> String {
        let p = Process()
        p.launchPath = "/usr/bin/git"
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: path)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if p.terminationStatus != 0 {
            throw WorktreeError.gitFailed(
                args: args, exitCode: p.terminationStatus, stderr: stderr
            )
        }
        return stdout + stderr
    }
}

public enum WorktreeError: Error, CustomStringConvertible {
    case gitFailed(args: [String], exitCode: Int32, stderr: String)
    public var description: String {
        switch self {
        case .gitFailed(let args, let code, let err):
            return "git \(args.joined(separator: " ")) exited \(code): \(err)"
        }
    }
}

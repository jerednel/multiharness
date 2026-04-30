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
        return home.appendingPathComponent(".multiharness").appendingPathComponent("workspaces", isDirectory: true)
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

    public func hasOriginRemote(repoPath: String) throws -> Bool {
        let out = try runGit(at: repoPath, args: ["remote"])
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .contains("origin")
    }

    public func listOriginBranches(repoPath: String) throws -> [String] {
        let out = try runGit(at: repoPath, args: [
            "for-each-ref", "refs/remotes/origin", "--format=%(refname:short)",
        ])
        return out.split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "origin/HEAD" }
    }

    /// Best-effort `git fetch origin` with a timeout. Throws on non-zero
    /// exit or when the timeout elapses.
    public func fetchOrigin(repoPath: String, timeoutSeconds: TimeInterval) throws {
        let p = Process()
        p.launchPath = "/usr/bin/git"
        p.arguments = ["fetch", "origin"]
        p.currentDirectoryURL = URL(fileURLWithPath: repoPath)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        try p.run()

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while p.isRunning {
            if Date() >= deadline {
                p.terminate()
                _ = p.waitUntilExit()
                throw WorktreeError.gitFailed(
                    args: ["fetch", "origin"],
                    exitCode: -1,
                    stderr: "fetch timed out after \(Int(timeoutSeconds))s"
                )
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            throw WorktreeError.gitFailed(
                args: ["fetch", "origin"],
                exitCode: p.terminationStatus,
                stderr: stderr
            )
        }
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

    public enum MergeResult: Equatable, Sendable {
        case clean
        case conflicts(unmergedFiles: [String])
    }

    /// Runs `git merge --no-ff --no-commit <sourceBranch>` in `worktreePath`.
    /// On a clean merge with no conflicts, returns `.clean` and the caller
    /// commits explicitly. On conflicts, parses unmerged paths and returns
    /// them; caller is responsible for resolving + staging + committing or
    /// calling `mergeAbort`.
    public func merge(worktreePath: URL, sourceBranch: String) throws -> MergeResult {
        do {
            _ = try runGit(at: worktreePath.path, args: [
                "merge", "--no-ff", "--no-commit", sourceBranch,
            ])
            return .clean
        } catch WorktreeError.gitFailed {
            // git merge exits non-zero on conflicts. Distinguish "had
            // conflicts" from "couldn't run at all" by checking unmerged.
            let unmerged = try unmergedFiles(worktreePath: worktreePath)
            if unmerged.isEmpty {
                // No unmerged paths but merge failed → genuine error.
                throw WorktreeError.gitFailed(
                    args: ["merge", "--no-ff", "--no-commit", sourceBranch],
                    exitCode: -1,
                    stderr: "merge failed without conflicts"
                )
            }
            return .conflicts(unmergedFiles: unmerged)
        }
    }

    /// Runs `git merge --abort`. Idempotent — silently succeeds if no merge
    /// is in progress.
    public func mergeAbort(worktreePath: URL) throws {
        _ = try? runGit(at: worktreePath.path, args: ["merge", "--abort"])
    }

    /// Returns paths of currently unmerged files.
    /// Output of `git diff --name-only --diff-filter=U`.
    public func unmergedFiles(worktreePath: URL) throws -> [String] {
        let out = try runGit(at: worktreePath.path, args: [
            "diff", "--name-only", "--diff-filter=U",
        ])
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Stage a path (`git add <path>`).
    public func stage(worktreePath: URL, path: String) throws {
        _ = try runGit(at: worktreePath.path, args: ["add", "--", path])
    }

    /// Commit staged changes with `message`.
    public func commit(worktreePath: URL, message: String) throws {
        _ = try runGit(at: worktreePath.path, args: ["commit", "-m", message])
    }

    /// Returns true if the file looks binary. We rely on git's own
    /// detection: `git diff --numstat` shows "-\t-\t<path>" for binary
    /// files. For files that don't exist or aren't tracked, returns false.
    public func isLikelyBinary(worktreePath: URL, path: String) -> Bool {
        guard let out = try? runGit(at: worktreePath.path, args: [
            "diff", "--numstat", "HEAD", "--", path,
        ]) else { return false }
        return out.contains("-\t-\t")
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

import Foundation

/// One-click "open a PR for what's in this worktree" flow.
///
/// Steps, executed sequentially with short-circuit on error:
///   1. `git add -A` to stage every dirty/untracked file. The whole point
///      of "one-click PR" is that the user shouldn't have to leave the
///      app to commit straggler files — we'd PR an incomplete feature
///      otherwise.
///   2. If anything is now staged, commit it with an auto message.
///   3. `git push -u origin <branch>` so GitHub knows about the branch.
///   4. `gh pr create --base <base> --head <branch> --fill` to open the PR
///      against the workspace's base branch and return the URL.
///
/// If `gh` isn't installed, step 4 degrades gracefully: we keep the push
/// and return the GitHub "compare/create-PR" URL synthesised from the
/// origin remote. The user gets a real link to click — they just open
/// the PR form in the browser instead of having it pre-filled by `gh`.
/// `Outcome.didCreatePr` distinguishes the two cases.
///
/// We deliberately keep this in `MultiharnessCore` (not in the view layer)
/// so the same flow is reachable from the iOS-driven remote API later.
public struct PullRequestService: Sendable {
    public init() {}

    /// What happened on each phase. Surfaced to the UI so the progress
    /// sheet can render a per-step checklist instead of a single opaque
    /// spinner.
    public struct Outcome: Sendable, Equatable {
        public var stagedFiles: [String]
        public var didCommit: Bool
        public var commitMessage: String?
        public var pushedBranch: String
        /// Either the URL `gh` returned, or — when `gh` isn't
        /// installed — the synthesized GitHub compare URL the user
        /// can click to open a PR in the browser.
        public var pullRequestUrl: String
        /// True iff `gh pr create` actually opened a PR. False when
        /// we fell back to "push + compare URL" because `gh` wasn't
        /// available. The sheet renders different copy for each.
        public var didCreatePr: Bool

        public init(
            stagedFiles: [String],
            didCommit: Bool,
            commitMessage: String?,
            pushedBranch: String,
            pullRequestUrl: String,
            didCreatePr: Bool
        ) {
            self.stagedFiles = stagedFiles
            self.didCommit = didCommit
            self.commitMessage = commitMessage
            self.pushedBranch = pushedBranch
            self.pullRequestUrl = pullRequestUrl
            self.didCreatePr = didCreatePr
        }
    }

    public enum Phase: String, Sendable {
        case staging
        case committing
        case pushing
        case opening
    }

    public enum Failure: Error, CustomStringConvertible, LocalizedError, Equatable {
        /// `gh` CLI couldn't be found on PATH or in known Homebrew
        /// locations. The orchestrator no longer throws this — it falls
        /// back to "push + compare URL". Kept for callers of
        /// `createPullRequest` that explicitly want to know.
        case ghMissing
        /// `git push` failed.
        case pushFailed(stderr: String)
        /// `gh pr create` failed (e.g. not authenticated, no remote, base
        /// branch missing on origin, …).
        case ghFailed(stderr: String)
        /// Worktree has zero changes vs its base branch AND no committed
        /// commits to PR — there's literally nothing to open a PR for.
        case nothingToPr
        /// A git invocation failed during staging/committing.
        case gitFailed(args: [String], stderr: String)
        /// `gh` is missing AND we couldn't synthesise a fallback compare
        /// URL (no `origin` remote, or it doesn't point at GitHub).
        case noFallbackUrl(reason: String)

        public var description: String {
            switch self {
            case .ghMissing:
                return "The GitHub CLI (`gh`) wasn't found. Install it with `brew install gh` and run `gh auth login`."
            case .pushFailed(let s):
                return "git push failed: \(s)"
            case .ghFailed(let s):
                return "gh pr create failed: \(s)"
            case .nothingToPr:
                return "Nothing to PR — this branch has no commits or pending changes vs its base."
            case .gitFailed(let args, let s):
                return "git \(args.joined(separator: " ")) failed: \(s)"
            case .noFallbackUrl(let r):
                return "Couldn't build a compare URL for this remote: \(r)"
            }
        }
        public var errorDescription: String? { description }
    }

    // MARK: - Pieces (each independently testable)

    /// Run `git add -A` and return the list of paths now staged.
    /// Idempotent: if there's nothing to stage, returns an empty array.
    public func stageAll(worktreePath: String) throws -> [String] {
        _ = try git(at: worktreePath, args: ["add", "-A"])
        // `--cached --name-only` lists staged paths against HEAD. On an
        // empty repo with no HEAD, that command exits non-zero; treat
        // that as "nothing staged".
        let out = (try? git(at: worktreePath, args: ["diff", "--cached", "--name-only"])) ?? ""
        return out.split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0) }
            .filter { !$0.isEmpty }
    }

    /// Commit currently-staged changes with `message`. Returns `true` if
    /// a commit was created, `false` if there was nothing staged.
    @discardableResult
    public func commitStaged(worktreePath: String, message: String) throws -> Bool {
        let staged = (try? git(at: worktreePath, args: ["diff", "--cached", "--name-only"])) ?? ""
        if staged.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return false
        }
        // Ensure committer identity exists even on a fresh machine. We
        // mirror what `WorktreeService.createWorktree` does for empty
        // repos: if the user hasn't configured `user.email`, fall back
        // to a stable local identity so the commit doesn't die.
        seedIdentityIfMissing(at: worktreePath)
        _ = try git(at: worktreePath, args: ["commit", "-m", message])
        return true
    }

    /// `git push -u origin <branch>`. Returns the push's stdout for
    /// debugging.
    @discardableResult
    public func push(worktreePath: String, branch: String) throws -> String {
        do {
            return try git(at: worktreePath, args: ["push", "-u", "origin", branch])
        } catch let WorktreeError.gitFailed(_, _, stderr) {
            throw Failure.pushFailed(stderr: stderr)
        }
    }

    /// `gh pr create --base <base> --head <branch> --fill`. Returns the
    /// PR URL printed on stdout by `gh`. If `title`/`body` are supplied
    /// they override `--fill`.
    public func createPullRequest(
        worktreePath: String,
        baseBranch: String,
        headBranch: String,
        title: String?,
        body: String?
    ) throws -> String {
        guard let gh = locateGh() else { throw Failure.ghMissing }
        var args = ["pr", "create", "--base", baseBranch, "--head", headBranch]
        if let title, !title.isEmpty {
            args.append(contentsOf: ["--title", title])
            args.append(contentsOf: ["--body", body ?? ""])
        } else {
            // --fill pulls title/body from the commit history. Falls back
            // sensibly when there's only one commit.
            args.append("--fill")
        }
        let (stdout, stderr, code) = run(executable: gh, args: args, cwd: worktreePath)
        if code != 0 {
            throw Failure.ghFailed(stderr: stderr.isEmpty ? stdout : stderr)
        }
        // `gh pr create` prints the PR URL on its own line; usually the
        // last non-empty line of stdout. Sniff for the first `https://`
        // token so we tolerate extra advisory output ("Creating draft
        // pull request for…").
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = trimmed.split(separator: "\n").map(String.init).reversed().first(where: {
            $0.hasPrefix("https://")
        }) {
            return url.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - Orchestrator

    /// One-click flow. `progress` is invoked on each phase change so the
    /// caller can render a step list.
    public func openPullRequest(
        worktreePath: String,
        branch: String,
        baseBranch: String,
        title: String? = nil,
        body: String? = nil,
        progress: ((Phase) -> Void)? = nil
    ) throws -> Outcome {
        progress?(.staging)
        let staged = try stageAll(worktreePath: worktreePath)

        progress?(.committing)
        let commitMessage = defaultCommitMessage(stagedFiles: staged, branch: branch)
        let didCommit = try commitStaged(worktreePath: worktreePath, message: commitMessage)

        // Guard against the "nothing to PR" case: no fresh commit AND
        // no commits on this branch vs base.
        if !didCommit {
            let ahead = (try? git(
                at: worktreePath,
                args: ["rev-list", "--count", "\(baseBranch)..HEAD"]
            ))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0"
            if ahead == "0" {
                throw Failure.nothingToPr
            }
        }

        progress?(.pushing)
        _ = try push(worktreePath: worktreePath, branch: branch)

        progress?(.opening)
        // Preferred path: gh creates the PR for us with a nice pre-filled
        // title/body. Fallback path: gh isn't installed, but a `git push`
        // already happened, so we hand the user a clickable compare-URL
        // pointing at the right base/head. They get one extra click to
        // hit "Create pull request" in the browser — but no work is lost.
        if locateGh() != nil {
            let url = try createPullRequest(
                worktreePath: worktreePath,
                baseBranch: baseBranch,
                headBranch: branch,
                title: title,
                body: body
            )
            return Outcome(
                stagedFiles: staged,
                didCommit: didCommit,
                commitMessage: didCommit ? commitMessage : nil,
                pushedBranch: branch,
                pullRequestUrl: url,
                didCreatePr: true
            )
        } else {
            let url = try fallbackCompareUrl(
                worktreePath: worktreePath,
                base: baseBranch,
                head: branch
            )
            return Outcome(
                stagedFiles: staged,
                didCommit: didCommit,
                commitMessage: didCommit ? commitMessage : nil,
                pushedBranch: branch,
                pullRequestUrl: url,
                didCreatePr: false
            )
        }
    }

    /// Synthesises a GitHub "compare across branches → create PR" URL
    /// from the `origin` remote and the supplied base/head. The result
    /// looks like:
    ///   `https://github.com/<owner>/<repo>/compare/<base>...<head>?expand=1`
    /// which lands the user on GitHub's PR-creation form with both refs
    /// already selected.
    public func fallbackCompareUrl(
        worktreePath: String,
        base: String,
        head: String
    ) throws -> String {
        let remote: String
        do {
            remote = try git(at: worktreePath, args: ["remote", "get-url", "origin"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.noFallbackUrl(reason: "no `origin` remote configured")
        }
        guard let slug = Self.githubSlug(fromRemoteUrl: remote) else {
            throw Failure.noFallbackUrl(reason: "origin `\(remote)` doesn't look like a GitHub URL")
        }
        let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? head
        return "https://github.com/\(slug)/compare/\(encodedBase)...\(encodedHead)?expand=1"
    }

    /// Parses an `origin` remote URL into the `owner/repo` slug GitHub
    /// uses in browser URLs. Handles the two formats `git remote get-url`
    /// emits in the wild:
    ///   - SSH:   `git@github.com:owner/repo.git`
    ///   - HTTPS: `https://github.com/owner/repo.git` (with or without `.git`)
    /// Returns `nil` for anything that doesn't smell like GitHub (e.g.
    /// GitLab, Bitbucket, self-hosted GitHub Enterprise on a custom
    /// host) — those would need their own URL templates.
    public static func githubSlug(fromRemoteUrl url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String? = nil
        if trimmed.hasPrefix("git@github.com:") {
            path = String(trimmed.dropFirst("git@github.com:".count))
        } else if trimmed.hasPrefix("ssh://git@github.com/") {
            path = String(trimmed.dropFirst("ssh://git@github.com/".count))
        } else if trimmed.hasPrefix("https://github.com/") {
            path = String(trimmed.dropFirst("https://github.com/".count))
        } else if trimmed.hasPrefix("http://github.com/") {
            path = String(trimmed.dropFirst("http://github.com/".count))
        }
        guard var p = path else { return nil }
        if p.hasSuffix(".git") { p.removeLast(4) }
        if p.hasSuffix("/") { p.removeLast() }
        // Must have exactly one slash separating owner and repo, both
        // non-empty.
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return "\(parts[0])/\(parts[1])"
    }

    // MARK: - Helpers

    /// Auto-generated commit message used when we need to sweep up any
    /// pending changes before opening a PR. Picks a one-line summary
    /// that reads better than "WIP" — names up to three files inline
    /// and trails off otherwise.
    public func defaultCommitMessage(stagedFiles: [String], branch: String) -> String {
        if stagedFiles.isEmpty {
            return "Sweep pending changes for \(branch)"
        }
        let preview = stagedFiles.prefix(3).joined(separator: ", ")
        let suffix = stagedFiles.count > 3 ? ", +\(stagedFiles.count - 3) more" : ""
        return "Sweep pending changes (\(preview)\(suffix))"
    }

    /// Returns the absolute path to `gh` if it's installed, otherwise
    /// `nil`. Tries a couple of well-known absolute paths first so the
    /// app works when launched from Finder (which doesn't inherit the
    /// user's shell PATH); falls back to `PATH` lookup.
    public func locateGh() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/usr/bin/gh",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // PATH fallback via `/usr/bin/env`.
        let (out, _, code) = run(
            executable: "/usr/bin/env",
            args: ["which", "gh"],
            cwd: NSTemporaryDirectory()
        )
        if code == 0 {
            let path = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty && FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        return nil
    }

    private func seedIdentityIfMissing(at path: String) {
        let name = (try? git(at: path, args: ["config", "user.name"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let email = (try? git(at: path, args: ["config", "user.email"]))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.isEmpty {
            _ = try? git(at: path, args: ["config", "user.name", "Multiharness"])
        }
        if email.isEmpty {
            _ = try? git(at: path, args: ["config", "user.email", "multiharness@local"])
        }
    }

    private func git(at path: String, args: [String]) throws -> String {
        let (stdout, stderr, code) = run(executable: "/usr/bin/git", args: args, cwd: path)
        if code != 0 {
            throw WorktreeError.gitFailed(args: args, exitCode: code, stderr: stderr)
        }
        return stdout
    }

    private func run(
        executable: String,
        args: [String],
        cwd: String
    ) -> (stdout: String, stderr: String, code: Int32) {
        let p = Process()
        p.launchPath = executable
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return ("", "failed to launch \(executable): \(error)", -1)
        }
        p.waitUntilExit()
        let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (stdout, stderr, p.terminationStatus)
    }
}

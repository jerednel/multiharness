import Foundation

/// Forge the workspace's `origin` remote points at. Drives which CLI
/// the orchestrator invokes (gh vs glab), which URL template to fall
/// back to when the CLI isn't installed, and how the UI words the
/// action ("Pull Request" vs "Merge Request").
public enum Forge: Equatable, Sendable {
    case github(slug: String)
    case gitlab(slug: String)

    public var slug: String {
        switch self {
        case .github(let s), .gitlab(let s): return s
        }
    }

    public var displayName: String {
        switch self {
        case .github: return "GitHub"
        case .gitlab: return "GitLab"
        }
    }

    /// Long-form noun. GitHub calls them "pull requests"; GitLab calls
    /// them "merge requests".
    public var requestNoun: String {
        switch self {
        case .github: return "pull request"
        case .gitlab: return "merge request"
        }
    }

    /// Two-letter abbreviation. Used in tight UI spots and in log lines.
    public var requestAbbrev: String {
        switch self {
        case .github: return "PR"
        case .gitlab: return "MR"
        }
    }

    /// Name of the CLI binary that creates the request. Matched by
    /// `PullRequestService.locateCli`.
    public var cliName: String {
        switch self {
        case .github: return "gh"
        case .gitlab: return "glab"
        }
    }

    /// Subcommand the CLI uses for the create-request action — `pr` for
    /// gh, `mr` for glab. Plumbed into log lines/error messages so a
    /// "gh mr create failed" never appears.
    public var cliRequestSubcommand: String {
        switch self {
        case .github: return "pr"
        case .gitlab: return "mr"
        }
    }
}

/// One-click "open a PR for what's in this worktree" flow.
///
/// Steps, executed sequentially with short-circuit on error:
///   1. `git add -A` to stage every dirty/untracked file. The whole point
///      of "one-click PR" is that the user shouldn't have to leave the
///      app to commit straggler files — we'd PR an incomplete feature
///      otherwise.
///   2. If anything is now staged, commit it with an auto message.
///   3. `git push -u origin <branch>` so the remote knows about the branch.
///   4. Forge-specific request creation:
///        - GitHub: `gh pr create --base <base> --head <branch> --fill`
///        - GitLab: `glab mr create --target-branch <base> --source-branch <branch> --fill`
///
/// If the forge's CLI isn't installed, step 4 degrades gracefully: we
/// keep the push and return the forge's "new PR/MR" URL synthesised from
/// the origin remote. The user gets a real link to click — they just
/// open the form in the browser instead of having it pre-filled by the
/// CLI. `Outcome.didCreatePr` distinguishes the two cases.
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
        /// Either the URL the forge CLI returned, or — when the CLI
        /// isn't installed — the synthesized "new PR/MR" URL the user
        /// can click to open the form in the browser.
        public var pullRequestUrl: String
        /// True iff the CLI actually opened a PR/MR. False when we fell
        /// back to "push + compare URL" because the CLI wasn't
        /// available. The sheet renders different copy for each.
        public var didCreatePr: Bool
        /// Forge the request was opened against. Drives forge-aware
        /// copy in the sheet ("Pull request opened" vs "Merge request
        /// opened").
        public var forge: Forge

        public init(
            stagedFiles: [String],
            didCommit: Bool,
            commitMessage: String?,
            pushedBranch: String,
            pullRequestUrl: String,
            didCreatePr: Bool,
            forge: Forge
        ) {
            self.stagedFiles = stagedFiles
            self.didCommit = didCommit
            self.commitMessage = commitMessage
            self.pushedBranch = pushedBranch
            self.pullRequestUrl = pullRequestUrl
            self.didCreatePr = didCreatePr
            self.forge = forge
        }
    }

    public enum Phase: String, Sendable {
        case staging
        case committing
        case pushing
        case opening
    }

    public enum Failure: Error, CustomStringConvertible, LocalizedError, Equatable {
        /// Forge CLI (gh or glab) couldn't be found on PATH or in known
        /// Homebrew locations. The orchestrator no longer throws this —
        /// it falls back to "push + compare URL". Kept for callers of
        /// `createPullRequest` that explicitly want to know.
        case cliMissing(forge: Forge)
        /// `git push` failed.
        case pushFailed(stderr: String)
        /// Forge CLI invocation failed (e.g. not authenticated, no
        /// remote, base branch missing, …).
        case cliFailed(forge: Forge, stderr: String)
        /// Worktree has zero changes vs its base branch AND no committed
        /// commits to PR — there's literally nothing to open a PR for.
        case nothingToPr
        /// A git invocation failed during staging/committing.
        case gitFailed(args: [String], stderr: String)
        /// Forge CLI is missing AND we couldn't synthesise a fallback
        /// compare URL (no `origin` remote, or it doesn't point at a
        /// recognised forge).
        case noFallbackUrl(reason: String)
        /// `origin` doesn't point at a recognised forge (gitlab.com,
        /// github.com). Self-hosted GitHub Enterprise / GitLab CE
        /// would land here today.
        case unrecognisedForge(remote: String)

        public var description: String {
            switch self {
            case .cliMissing(let f):
                let installHint: String
                switch f {
                case .github: installHint = "Install it with `brew install gh` and run `gh auth login`."
                case .gitlab: installHint = "Install it with `brew install glab` and run `glab auth login`."
                }
                return "The \(f.displayName) CLI (`\(f.cliName)`) wasn't found. \(installHint)"
            case .pushFailed(let s):
                return "git push failed: \(s)"
            case .cliFailed(let f, let s):
                return "`\(f.cliName) \(f.cliRequestSubcommand) create` failed: \(s)"
            case .nothingToPr:
                return "Nothing to PR — this branch has no commits or pending changes vs its base."
            case .gitFailed(let args, let s):
                return "git \(args.joined(separator: " ")) failed: \(s)"
            case .noFallbackUrl(let r):
                return "Couldn't build a compare URL for this remote: \(r)"
            case .unrecognisedForge(let remote):
                return "`origin` remote `\(remote)` isn't a recognised forge. Only github.com and gitlab.com are supported."
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

    /// Forge-aware "create the request" call. Dispatches on `forge`:
    ///   - GitHub: `gh pr create --base <base> --head <branch> [--fill | --title/--body]`
    ///   - GitLab: `glab mr create --target-branch <base> --source-branch <branch> [--fill | --title/--description]`
    /// Returns the URL printed by the CLI on stdout.
    public func createPullRequest(
        worktreePath: String,
        forge: Forge,
        baseBranch: String,
        headBranch: String,
        title: String?,
        body: String?
    ) throws -> String {
        guard let cli = locateCli(name: forge.cliName) else {
            throw Failure.cliMissing(forge: forge)
        }
        var args: [String]
        switch forge {
        case .github:
            args = ["pr", "create", "--base", baseBranch, "--head", headBranch]
            if let title, !title.isEmpty {
                args.append(contentsOf: ["--title", title])
                args.append(contentsOf: ["--body", body ?? ""])
            } else {
                args.append("--fill")
            }
        case .gitlab:
            args = [
                "mr", "create",
                "--target-branch", baseBranch,
                "--source-branch", headBranch,
            ]
            if let title, !title.isEmpty {
                args.append(contentsOf: ["--title", title])
                args.append(contentsOf: ["--description", body ?? ""])
            } else {
                args.append("--fill")
            }
        }
        let (stdout, stderr, code) = run(executable: cli, args: args, cwd: worktreePath)
        if code != 0 {
            throw Failure.cliFailed(forge: forge, stderr: stderr.isEmpty ? stdout : stderr)
        }
        // Both CLIs print the request URL somewhere in stdout — usually
        // the last `https://` line. Sniff for that so we tolerate
        // advisory chatter ("Creating draft pull request for…",
        // "Updating origin/branch…").
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
    /// caller can render a step list. Forge detection happens at the
    /// "opening" step (not up front) so the push leg still benefits the
    /// user even on origins we can't open a PR/MR against — the branch
    /// lands; we just can't auto-create the request.
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
        // Resolve the forge now — after the push, so the branch lands
        // regardless. Throws .unrecognisedForge / .noFallbackUrl when
        // the remote isn't gitlab.com / github.com.
        let forge = try detectForgeFromOrigin(worktreePath: worktreePath)
        // Preferred path: the forge CLI creates the request for us with
        // a nice pre-filled title/body. Fallback path: the CLI isn't
        // installed, but a `git push` already happened, so we hand the
        // user a clickable compare-URL pointing at the right base/head.
        // They get one extra click to hit "Create" in the browser — but
        // no work is lost.
        if locateCli(name: forge.cliName) != nil {
            let url = try createPullRequest(
                worktreePath: worktreePath,
                forge: forge,
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
                didCreatePr: true,
                forge: forge
            )
        } else {
            let url = fallbackCompareUrl(forge: forge, base: baseBranch, head: branch)
            return Outcome(
                stagedFiles: staged,
                didCommit: didCommit,
                commitMessage: didCommit ? commitMessage : nil,
                pushedBranch: branch,
                pullRequestUrl: url,
                didCreatePr: false,
                forge: forge
            )
        }
    }

    /// Read `origin` and resolve it to a `Forge`. Throws
    /// `Failure.noFallbackUrl` if there's no origin and
    /// `Failure.unrecognisedForge` if the remote points at something
    /// other than github.com / gitlab.com.
    public func detectForgeFromOrigin(worktreePath: String) throws -> Forge {
        let remote: String
        do {
            remote = try git(at: worktreePath, args: ["remote", "get-url", "origin"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw Failure.noFallbackUrl(reason: "no `origin` remote configured")
        }
        guard let forge = Self.detectForge(fromRemoteUrl: remote) else {
            throw Failure.unrecognisedForge(remote: remote)
        }
        return forge
    }

    /// Synthesises the forge's "open a new PR/MR" URL with the supplied
    /// branches pre-filled. Templates:
    ///   - GitHub: `https://github.com/<slug>/compare/<base>...<head>?expand=1`
    ///   - GitLab: `https://gitlab.com/<slug>/-/merge_requests/new?merge_request[source_branch]=<head>&merge_request[target_branch]=<base>`
    public func fallbackCompareUrl(forge: Forge, base: String, head: String) -> String {
        let encodedBase = base.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? base
        let encodedHead = head.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? head
        switch forge {
        case .github(let slug):
            return "https://github.com/\(slug)/compare/\(encodedBase)...\(encodedHead)?expand=1"
        case .gitlab(let slug):
            // GitLab uses bracketed query keys; URL-encode them so
            // `URL(string:)` doesn't choke on the raw `[`/`]`.
            let src = "merge_request%5Bsource_branch%5D=\(encodedHead)"
            let dst = "merge_request%5Btarget_branch%5D=\(encodedBase)"
            return "https://gitlab.com/\(slug)/-/merge_requests/new?\(src)&\(dst)"
        }
    }

    /// Resolves an `origin` URL to a `Forge` (with owner/repo slug) or
    /// `nil` if the host isn't gitlab.com or github.com. Handles the
    /// URL shapes `git remote get-url` emits in the wild:
    ///   - SSH:   `git@<host>:owner/repo.git`
    ///   - SSH:   `ssh://git@<host>/owner/repo.git`
    ///   - HTTPS: `https://<host>/owner/repo.git` (with or without `.git`)
    public static func detectForge(fromRemoteUrl url: String) -> Forge? {
        if let slug = slug(fromRemoteUrl: url, host: "github.com") {
            return .github(slug: slug)
        }
        if let slug = slug(fromRemoteUrl: url, host: "gitlab.com") {
            return .gitlab(slug: slug)
        }
        return nil
    }

    /// Back-compat shim — older callers and tests reference this
    /// directly. Returns the slug iff the URL points at github.com.
    public static func githubSlug(fromRemoteUrl url: String) -> String? {
        slug(fromRemoteUrl: url, host: "github.com")
    }

    /// Generic owner/repo extractor for a known host. Returns nil if
    /// the URL doesn't match any of the four supported shapes for the
    /// given host.
    public static func slug(fromRemoteUrl url: String, host: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        var path: String?
        let sshAt = "git@\(host):"
        let sshUrl = "ssh://git@\(host)/"
        let httpsUrl = "https://\(host)/"
        let httpUrl = "http://\(host)/"
        if trimmed.hasPrefix(sshAt) {
            path = String(trimmed.dropFirst(sshAt.count))
        } else if trimmed.hasPrefix(sshUrl) {
            path = String(trimmed.dropFirst(sshUrl.count))
        } else if trimmed.hasPrefix(httpsUrl) {
            path = String(trimmed.dropFirst(httpsUrl.count))
        } else if trimmed.hasPrefix(httpUrl) {
            path = String(trimmed.dropFirst(httpUrl.count))
        }
        guard var p = path else { return nil }
        if p.hasSuffix(".git") { p.removeLast(4) }
        if p.hasSuffix("/") { p.removeLast() }
        // GitLab supports subgroups (owner/sub/repo) — accept any depth
        // ≥ 2 segments. GitHub's normal shape is exactly 2, but the
        // permissive path here is symmetric (and matches what gh/glab
        // accept on their end).
        let parts = p.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, !parts.allSatisfy({ $0.isEmpty }) else { return nil }
        if parts.contains(where: { $0.isEmpty }) { return nil }
        return parts.joined(separator: "/")
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

    /// Back-compat alias for callers that asked specifically about `gh`.
    public func locateGh() -> String? { locateCli(name: "gh") }

    /// Returns the absolute path to a CLI binary (`gh`, `glab`, …) if
    /// it's installed, otherwise `nil`. Tries well-known absolute paths
    /// first so the app works when launched from Finder (which doesn't
    /// inherit the user's shell PATH); falls back to `PATH` lookup.
    public func locateCli(name: String) -> String? {
        let candidates = [
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/usr/bin/\(name)",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // PATH fallback via `/usr/bin/env`.
        let (out, _, code) = run(
            executable: "/usr/bin/env",
            args: ["which", name],
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

import XCTest
@testable import MultiharnessCore

/// Covers the pieces of the one-click-PR flow that don't require `gh` or
/// network access — staging, committing, and pushing to a local bare
/// "remote". The `gh pr create` leg is intentionally out of scope here;
/// it's exercised end-to-end manually because it requires
/// authentication.
final class PullRequestServiceTests: XCTestCase {
    var repoDir: URL!
    var remoteDir: URL!
    let svc = PullRequestService()
    let worktreeSvc = WorktreeService()

    override func setUpWithError() throws {
        remoteDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-pr-remote-\(UUID().uuidString).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try worktreeSvc.runGit(at: remoteDir.path, args: ["init", "--bare", "-q", "-b", "main"])

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-pr-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try worktreeSvc.runGit(at: parent.path, args: [
            "clone", "-q", remoteDir.path, "work",
        ])
        repoDir = parent.appendingPathComponent("work", isDirectory: true)
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["config", "user.email", "test@test"])
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["config", "user.name", "Test"])
        try "hello\n".write(
            to: repoDir.appendingPathComponent("seed.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["push", "-q", "origin", "main"])
        // Branch off for our PR.
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: remoteDir)
    }

    /// `stageAll` should pull in both modified-tracked files and brand
    /// new untracked files — that's the whole point of staging "all"
    /// before opening a PR.
    func testStageAllPicksUpModifiedAndUntrackedFiles() throws {
        // Modify a tracked file
        try "hello world\n".write(
            to: repoDir.appendingPathComponent("seed.txt"),
            atomically: true, encoding: .utf8
        )
        // Add an untracked one
        try "new\n".write(
            to: repoDir.appendingPathComponent("new.txt"),
            atomically: true, encoding: .utf8
        )

        let staged = try svc.stageAll(worktreePath: repoDir.path)
        XCTAssertTrue(staged.contains("seed.txt"), "modified tracked file was staged")
        XCTAssertTrue(staged.contains("new.txt"), "untracked file was staged")
    }

    func testStageAllOnCleanRepoReturnsEmpty() throws {
        let staged = try svc.stageAll(worktreePath: repoDir.path)
        XCTAssertTrue(staged.isEmpty)
    }

    func testCommitStagedCreatesCommitWhenSomethingIsStaged() throws {
        try "x\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.stageAll(worktreePath: repoDir.path)
        let did = try svc.commitStaged(worktreePath: repoDir.path, message: "test commit")
        XCTAssertTrue(did)
        let log = try worktreeSvc.runGit(at: repoDir.path, args: ["log", "-1", "--pretty=%s"])
        XCTAssertTrue(log.contains("test commit"))
    }

    func testCommitStagedNoopWhenNothingStaged() throws {
        let did = try svc.commitStaged(worktreePath: repoDir.path, message: "noop")
        XCTAssertFalse(did)
    }

    func testPushBranchSucceedsAgainstBareRemote() throws {
        try "feat\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.stageAll(worktreePath: repoDir.path)
        _ = try svc.commitStaged(worktreePath: repoDir.path, message: "feat")
        XCTAssertNoThrow(try svc.push(worktreePath: repoDir.path, branch: "feature"))
        // The bare remote should now have the branch.
        let refs = try worktreeSvc.runGit(at: remoteDir.path, args: [
            "for-each-ref", "--format=%(refname:short)", "refs/heads/",
        ])
        XCTAssertTrue(refs.contains("feature"))
    }

    func testPushFailureSurfacesAsPushFailed() throws {
        // Point origin at nothingness.
        _ = try worktreeSvc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "/nonexistent/path/repo.git",
        ])
        // Need at least one commit to push.
        try "x\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.stageAll(worktreePath: repoDir.path)
        _ = try svc.commitStaged(worktreePath: repoDir.path, message: "x")
        XCTAssertThrowsError(try svc.push(worktreePath: repoDir.path, branch: "feature")) { err in
            if case PullRequestService.Failure.pushFailed = err {
                // expected
            } else {
                XCTFail("expected pushFailed, got \(err)")
            }
        }
    }

    func testDefaultCommitMessageSummarisesFileList() {
        XCTAssertEqual(
            svc.defaultCommitMessage(stagedFiles: [], branch: "b"),
            "Sweep pending changes for b"
        )
        XCTAssertEqual(
            svc.defaultCommitMessage(stagedFiles: ["a.txt"], branch: "b"),
            "Sweep pending changes (a.txt)"
        )
        XCTAssertEqual(
            svc.defaultCommitMessage(stagedFiles: ["a", "b", "c", "d", "e"], branch: "br"),
            "Sweep pending changes (a, b, c, +2 more)"
        )
    }

    /// Full orchestrator up to (but not including) the `gh` step.
    /// Three outcomes are acceptable here, depending on the host:
    ///   - `gh` not installed AND origin doesn't look like GitHub →
    ///     fall back to `noFallbackUrl` (our bare local path).
    ///   - `gh` installed but unauthenticated against the fake remote
    ///     → `.ghFailed`.
    ///   - `gh` somehow happy with the bare remote → success.
    /// In every case, by the time the call returns we must have pushed
    /// to the bare remote and visited all four phases.
    func testOpenPullRequestRunsAllPhasesAndPushes() throws {
        try "stuff\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        var seenPhases: [PullRequestService.Phase] = []
        do {
            _ = try svc.openPullRequest(
                worktreePath: repoDir.path,
                branch: "feature",
                baseBranch: "main",
                progress: { seenPhases.append($0) }
            )
        } catch let err as PullRequestService.Failure {
            switch err {
            case .noFallbackUrl, .ghFailed:
                break  // expected on hosts without `gh` (local origin
                       // isn't github.com, so no fallback URL) or with
                       // `gh` that hates our fake remote.
            default:
                XCTFail("unexpected failure \(err)")
            }
        }
        XCTAssertEqual(seenPhases.prefix(4),
                       [.staging, .committing, .pushing, .opening])
        // The push must have landed regardless of which branch we took.
        let refs = try worktreeSvc.runGit(at: remoteDir.path, args: [
            "for-each-ref", "--format=%(refname:short)", "refs/heads/",
        ])
        XCTAssertTrue(refs.contains("feature"))
    }

    /// When the origin DOES look like GitHub, and `gh` isn't installed,
    /// the orchestrator should produce a successful Outcome with
    /// `didCreatePr == false` and a synthesised compare URL.
    /// We force the "gh missing" branch by pointing origin at a
    /// github.com URL that doesn't actually exist; the push will fail,
    /// so we exercise the URL synthesis via `fallbackCompareUrl`
    /// directly. (Going through `openPullRequest` would require either
    /// hitting the network or stubbing gh discovery, neither of which
    /// belong in a unit test.)
    func testFallbackCompareUrlForGithubSshOrigin() throws {
        _ = try worktreeSvc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "git@github.com:acme/widgets.git",
        ])
        let url = try svc.fallbackCompareUrl(
            worktreePath: repoDir.path,
            base: "main",
            head: "feature"
        )
        XCTAssertEqual(
            url,
            "https://github.com/acme/widgets/compare/main...feature?expand=1"
        )
    }

    func testFallbackCompareUrlForGithubHttpsOrigin() throws {
        _ = try worktreeSvc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "https://github.com/acme/widgets.git",
        ])
        let url = try svc.fallbackCompareUrl(
            worktreePath: repoDir.path,
            base: "main",
            head: "feature/foo"
        )
        // GitHub accepts slashes literally in compare URLs (it's how
        // `feature/foo`-style branch names work in the browser). We
        // pass them through `.urlPathAllowed`, which leaves `/`
        // unescaped — that's the intended behavior.
        XCTAssertEqual(
            url,
            "https://github.com/acme/widgets/compare/main...feature/foo?expand=1"
        )
    }

    func testFallbackCompareUrlRejectsNonGithubOrigin() throws {
        _ = try worktreeSvc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "git@gitlab.com:acme/widgets.git",
        ])
        XCTAssertThrowsError(
            try svc.fallbackCompareUrl(
                worktreePath: repoDir.path,
                base: "main",
                head: "feature"
            )
        ) { err in
            if case PullRequestService.Failure.noFallbackUrl = err {
                // expected
            } else {
                XCTFail("expected noFallbackUrl, got \(err)")
            }
        }
    }

    func testGithubSlugParserHandlesCommonShapes() {
        XCTAssertEqual(
            PullRequestService.githubSlug(fromRemoteUrl: "git@github.com:acme/widgets.git"),
            "acme/widgets"
        )
        XCTAssertEqual(
            PullRequestService.githubSlug(fromRemoteUrl: "git@github.com:acme/widgets"),
            "acme/widgets"
        )
        XCTAssertEqual(
            PullRequestService.githubSlug(fromRemoteUrl: "https://github.com/acme/widgets.git"),
            "acme/widgets"
        )
        XCTAssertEqual(
            PullRequestService.githubSlug(fromRemoteUrl: "https://github.com/acme/widgets/"),
            "acme/widgets"
        )
        XCTAssertEqual(
            PullRequestService.githubSlug(fromRemoteUrl: "ssh://git@github.com/acme/widgets.git"),
            "acme/widgets"
        )
        XCTAssertNil(
            PullRequestService.githubSlug(fromRemoteUrl: "git@gitlab.com:acme/widgets.git"),
            "non-github hosts should not match"
        )
        XCTAssertNil(
            PullRequestService.githubSlug(fromRemoteUrl: "https://github.com/acme"),
            "owner-only URL is not a valid slug"
        )
        XCTAssertNil(
            PullRequestService.githubSlug(fromRemoteUrl: ""),
            "empty input"
        )
    }

    func testOpenPullRequestFailsWithNothingToPrOnCleanRepoWithNoAhead() throws {
        // Stay on main (no commits ahead of itself), nothing dirty.
        _ = try worktreeSvc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        XCTAssertThrowsError(
            try svc.openPullRequest(
                worktreePath: repoDir.path,
                branch: "main",
                baseBranch: "main"
            )
        ) { err in
            if case PullRequestService.Failure.nothingToPr = err {
                // expected
            } else {
                XCTFail("expected nothingToPr, got \(err)")
            }
        }
    }
}

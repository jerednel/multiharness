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

    /// Full orchestrator up to (but not including) the `gh` step:
    /// stage + commit + push should all run cleanly, and we should
    /// then fail at the `gh` step with `.ghMissing` on machines that
    /// don't have it. On machines that DO have `gh` but aren't
    /// authenticated against a fake bare repo, we'd see `.ghFailed` —
    /// either is acceptable here; we just assert "we got that far".
    func testOpenPullRequestFailsCleanlyAtGhStep() throws {
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
            // If `gh` IS installed and somehow authenticated against
            // our bare local "remote", treat that as success — the
            // important behavioral check is that we made it through.
        } catch let err as PullRequestService.Failure {
            switch err {
            case .ghMissing, .ghFailed:
                break  // expected
            default:
                XCTFail("unexpected failure \(err)")
            }
        }
        XCTAssertEqual(seenPhases.prefix(4),
                       [.staging, .committing, .pushing, .opening])
        // The push must have actually landed before we tried `gh`.
        let refs = try worktreeSvc.runGit(at: remoteDir.path, args: [
            "for-each-ref", "--format=%(refname:short)", "refs/heads/",
        ])
        XCTAssertTrue(refs.contains("feature"))
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

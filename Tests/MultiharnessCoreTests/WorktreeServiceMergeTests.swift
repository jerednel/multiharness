import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class WorktreeServiceMergeTests: XCTestCase {
    var repoDir: URL!
    var worktreeDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-merge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: repoDir.path, args: ["init", "-q", "-b", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "test@test"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "Test"])
        try "hello\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir)
    }

    func testCleanMerge() throws {
        // branch A: append line
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-a"])
        try "hello\nfrom a\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "a"])
        // back to main, create integration branch
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "integration"])
        // merge feature-a into integration; expect clean
        let result = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-a")
        XCTAssertEqual(result, .clean)
        try svc.commit(worktreePath: repoDir, message: "Reconcile: merge feature-a")
    }

    func testConflictingMerge() throws {
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-a"])
        try "hello\nfrom a\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "a"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "feature-b"])
        try "hello\nfrom b\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-aq", "-m", "b"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "integration"])
        _ = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-a")
        try svc.commit(worktreePath: repoDir, message: "Reconcile: merge feature-a")
        let result = try svc.merge(worktreePath: repoDir, sourceBranch: "feature-b")
        guard case .conflicts(let files) = result else {
            return XCTFail("expected .conflicts, got \(result)")
        }
        XCTAssertEqual(files, ["a.txt"])
    }

    func testMergeAbortRestoresClean() throws {
        try testConflictingMerge()
        try svc.mergeAbort(worktreePath: repoDir)
        let unmerged = try svc.unmergedFiles(worktreePath: repoDir)
        XCTAssertEqual(unmerged, [])
    }

    func testStageAndCommit() throws {
        try "manually resolved\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        try svc.stage(worktreePath: repoDir, path: "a.txt")
        try svc.commit(worktreePath: repoDir, message: "manual fix")
        let log = try svc.runGit(at: repoDir.path, args: ["log", "--oneline", "-1"])
        XCTAssertTrue(log.contains("manual fix"))
    }
}

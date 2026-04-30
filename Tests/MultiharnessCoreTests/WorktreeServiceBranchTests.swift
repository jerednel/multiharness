import XCTest
@testable import MultiharnessCore

final class WorktreeServiceBranchTests: XCTestCase {
    var repoDir: URL!
    var remoteDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        // Bare "remote" repo
        remoteDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branch-remote-\(UUID().uuidString).git", isDirectory: true)
        try FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: remoteDir.path, args: ["init", "--bare", "-q", "-b", "main"])

        // Working repo, cloned from the bare remote
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branch-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try svc.runGit(at: parent.path, args: [
            "clone", "-q", remoteDir.path, "work",
        ])
        repoDir = parent.appendingPathComponent("work", isDirectory: true)
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "test@test"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "Test"])
        try "hello\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
        _ = try svc.runGit(at: repoDir.path, args: ["push", "-q", "origin", "main"])
        // Add a second remote branch
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "-b", "develop"])
        _ = try svc.runGit(at: repoDir.path, args: ["push", "-q", "-u", "origin", "develop"])
        _ = try svc.runGit(at: repoDir.path, args: ["checkout", "-q", "main"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: remoteDir)
    }

    func testHasOriginRemote() throws {
        XCTAssertTrue(try svc.hasOriginRemote(repoPath: repoDir.path))
    }

    func testHasOriginRemoteFalseWhenAbsent() throws {
        let solo = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-solo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: solo, withIntermediateDirectories: true)
        _ = try svc.runGit(at: solo.path, args: ["init", "-q", "-b", "main"])
        defer { try? FileManager.default.removeItem(at: solo) }
        XCTAssertFalse(try svc.hasOriginRemote(repoPath: solo.path))
    }

    func testListOriginBranchesReturnsRemoteRefs() throws {
        let branches = try svc.listOriginBranches(repoPath: repoDir.path)
        XCTAssertTrue(branches.contains("origin/main"))
        XCTAssertTrue(branches.contains("origin/develop"))
        XCTAssertFalse(branches.contains(where: { $0.contains("HEAD") }))
    }

    func testFetchOriginSucceedsWhenReachable() throws {
        XCTAssertNoThrow(try svc.fetchOrigin(repoPath: repoDir.path, timeoutSeconds: 5))
    }

    func testFetchOriginThrowsOnUnreachableRemote() throws {
        // Repoint origin at a path that doesn't exist
        _ = try svc.runGit(at: repoDir.path, args: [
            "remote", "set-url", "origin", "/nonexistent/path/repo.git",
        ])
        XCTAssertThrowsError(try svc.fetchOrigin(repoPath: repoDir.path, timeoutSeconds: 5))
    }
}

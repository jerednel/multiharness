// Tests/MultiharnessCoreTests/BranchListServiceTests.swift
import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class BranchListServiceTests: XCTestCase {
    var repoDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        // Standalone repo (no remote) for cache tests.
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-branchsvc-\(UUID().uuidString)", isDirectory: true)
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

    func testListReportsNoRemoteWhenAbsent() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        let listing = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        XCTAssertFalse(listing.originAvailable)
        XCTAssertEqual(listing.originUnavailableReason, .noRemote)
        XCTAssertNil(listing.origin)
        XCTAssertTrue(listing.local.contains("main"))
    }

    func testCacheReturnedOnSecondCall() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        let first = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        // Add a new local branch — without `refresh`, the service should
        // return the cached listing that doesn't include it.
        _ = try svc.runGit(at: repoDir.path, args: ["branch", "topic"])
        let second = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        XCTAssertEqual(first.local, second.local)
        XCTAssertFalse(second.local.contains("topic"))
    }

    func testRefreshBypassesCache() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        _ = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        _ = try svc.runGit(at: repoDir.path, args: ["branch", "topic"])
        let refreshed = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: true)
        XCTAssertTrue(refreshed.local.contains("topic"))
    }

    func testFetchFailureMarksOriginUnavailable() async throws {
        // Add a broken origin remote
        _ = try svc.runGit(at: repoDir.path, args: [
            "remote", "add", "origin", "/nonexistent/path/repo.git",
        ])
        let service = BranchListService(worktree: svc)
        let listing = try await service.list(
            projectId: UUID(), repoPath: repoDir.path, refresh: true
        )
        XCTAssertFalse(listing.originAvailable)
        XCTAssertEqual(listing.originUnavailableReason, .fetchFailed)
    }

    func testInvalidateClearsCache() async throws {
        let pid = UUID()
        let service = BranchListService(worktree: svc)
        _ = try await service.list(projectId: pid, repoPath: repoDir.path, refresh: false)
        _ = try svc.runGit(at: repoDir.path, args: ["branch", "topic"])
        await service.invalidate(projectId: pid)
        let fresh = try await service.list(
            projectId: pid, repoPath: repoDir.path, refresh: false
        )
        XCTAssertTrue(fresh.local.contains("topic"))
    }
}

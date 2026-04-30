import XCTest
@testable import MultiharnessCore
import MultiharnessClient

@MainActor
final class RemoteHandlersBranchTests: XCTestCase {
    var repoDir: URL!
    let svc = WorktreeService()

    override func setUpWithError() throws {
        repoDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-rh-branch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repoDir, withIntermediateDirectories: true)
        _ = try svc.runGit(at: repoDir.path, args: ["init", "-q", "-b", "main"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.email", "t@t"])
        _ = try svc.runGit(at: repoDir.path, args: ["config", "user.name", "T"])
        try "x\n".write(
            to: repoDir.appendingPathComponent("a.txt"),
            atomically: true, encoding: .utf8
        )
        _ = try svc.runGit(at: repoDir.path, args: ["add", "."])
        _ = try svc.runGit(at: repoDir.path, args: ["commit", "-q", "-m", "init"])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: repoDir)
    }

    func testListBranchesNoRemote() async throws {
        let projectId = UUID()
        let service = BranchListService(worktree: svc)
        let result = try await RemoteBranchHandler.handleListBranches(
            params: [
                "projectId": projectId.uuidString,
                "refresh": false,
            ],
            repoPath: repoDir.path,
            service: service
        ) as? [String: Any]
        XCTAssertEqual(result?["originAvailable"] as? Bool, false)
        XCTAssertEqual(result?["originUnavailableReason"] as? String, "no_remote")
        XCTAssertTrue(((result?["local"] as? [String]) ?? []).contains("main"))
    }

    func testListBranchesRequiresProjectId() async {
        let service = BranchListService(worktree: svc)
        do {
            _ = try await RemoteBranchHandler.handleListBranches(
                params: [:],
                repoPath: repoDir.path,
                service: service
            )
            XCTFail("expected error")
        } catch {
            // expected
        }
    }
}

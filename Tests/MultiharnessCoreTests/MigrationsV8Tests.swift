import XCTest
@testable import MultiharnessCore
import MultiharnessClient

/// Schema-v8 round-trip coverage for the QA auto-apply columns.
final class MigrationsV8Tests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProjectDefaultAutoApplyDefaultsOff() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let p = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertFalse(loaded.defaultQaAutoApply)
    }

    func testProjectDefaultAutoApplyRoundtrip() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let p = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultQaAutoApply: true
        )
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertTrue(loaded.defaultQaAutoApply)
    }

    func testWorkspaceQaAutoApplyNullByDefault() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: prov.id, modelId: "m"
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertNil(loaded.qaAutoApply)
    }

    func testWorkspaceQaAutoApplyExplicitFalseRoundtrips() throws {
        // Same critical case as qaEnabled: false ≠ NULL. The popover
        // needs to distinguish "explicit opt-out" from "inherit".
        let svc = try PersistenceService(dataDir: try tempDir())
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultQaAutoApply: true)
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: prov.id, modelId: "m",
            qaAutoApply: false
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertEqual(loaded.qaAutoApply, false)
    }

    func testWorkspaceQaAutoApplyExplicitTrueRoundtrips() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: prov.id, modelId: "m",
            qaAutoApply: true
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertEqual(loaded.qaAutoApply, true)
    }

    func testUpsertRetainsAutoApplyAcrossUpdates() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        var proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultQaAutoApply: true
        )
        try svc.upsertProject(proj)
        proj.contextInstructions = "use pnpm"
        try svc.upsertProject(proj)
        let loaded = try svc.listProjects().first!
        XCTAssertTrue(loaded.defaultQaAutoApply)
    }
}

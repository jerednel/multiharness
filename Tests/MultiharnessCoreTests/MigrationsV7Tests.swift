import XCTest
@testable import MultiharnessCore
import MultiharnessClient

/// Schema-v7 round-trip coverage: every new column survives upsert→list
/// for both Project and Workspace, with the cross-product of "set" /
/// "unset" / "default" combinations the UI can produce.
final class MigrationsV7Tests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Project defaults

    func testProjectQaDefaultsAllUnsetByDefault() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let p = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertFalse(loaded.defaultQaEnabled)
        XCTAssertNil(loaded.defaultQaProviderId)
        XCTAssertNil(loaded.defaultQaModelId)
    }

    func testProjectQaEnabledRoundtrip() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let p = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultQaEnabled: true)
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertTrue(loaded.defaultQaEnabled)
    }

    func testProjectQaProviderAndModelRoundtrip() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let pid = UUID()
        let p = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultQaProviderId: pid,
            defaultQaModelId: "claude-3-7-sonnet"
        )
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertEqual(loaded.defaultQaProviderId, pid)
        XCTAssertEqual(loaded.defaultQaModelId, "claude-3-7-sonnet")
    }

    func testProjectQaModelPersistsIndependentOfEnabledFlag() throws {
        // Spec: a project may set a default model without enabling QA —
        // the model is staged for any workspace that later opts in.
        let svc = try PersistenceService(dataDir: try tempDir())
        let pid = UUID()
        let p = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultQaEnabled: false,
            defaultQaProviderId: pid,
            defaultQaModelId: "claude-3-7-sonnet"
        )
        try svc.upsertProject(p)
        let loaded = try svc.listProjects().first!
        XCTAssertFalse(loaded.defaultQaEnabled)
        XCTAssertEqual(loaded.defaultQaProviderId, pid)
        XCTAssertEqual(loaded.defaultQaModelId, "claude-3-7-sonnet")
    }

    // MARK: - Workspace overrides

    func testWorkspaceQaOverridesAllUnsetByDefault() throws {
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
        XCTAssertNil(loaded.qaEnabled)
        XCTAssertNil(loaded.qaProviderId)
        XCTAssertNil(loaded.qaModelId)
    }

    func testWorkspaceQaEnabledExplicitFalseRoundtrips() throws {
        // The critical distinguishing case: false ≠ NULL. An explicit
        // opt-out must come back as false, not nil — otherwise the
        // "Use project default" affordance can't render correctly.
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
            qaEnabled: false
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertEqual(loaded.qaEnabled, false)
    }

    func testWorkspaceQaEnabledExplicitTrueRoundtrips() throws {
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
            qaEnabled: true
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertEqual(loaded.qaEnabled, true)
    }

    func testWorkspaceQaProviderAndModelRoundtrip() throws {
        let svc = try PersistenceService(dataDir: try tempDir())
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        let qaPid = UUID()
        let ws = Workspace(
            projectId: proj.id,
            name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: prov.id, modelId: "m",
            qaProviderId: qaPid,
            qaModelId: "gpt-5-mini"
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id).first!
        XCTAssertEqual(loaded.qaProviderId, qaPid)
        XCTAssertEqual(loaded.qaModelId, "gpt-5-mini")
    }

    func testUpsertRetainsQaFieldsAcrossUpdates() throws {
        // The UPSERT clause must list every new column so an unrelated
        // update doesn't accidentally clobber the user's QA settings.
        let svc = try PersistenceService(dataDir: try tempDir())
        let qaPid = UUID()
        var proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultQaEnabled: true,
            defaultQaProviderId: qaPid,
            defaultQaModelId: "claude-3-7-sonnet"
        )
        try svc.upsertProject(proj)
        // Unrelated change.
        proj.contextInstructions = "use pnpm"
        try svc.upsertProject(proj)
        let loaded = try svc.listProjects().first!
        XCTAssertTrue(loaded.defaultQaEnabled)
        XCTAssertEqual(loaded.defaultQaProviderId, qaPid)
        XCTAssertEqual(loaded.defaultQaModelId, "claude-3-7-sonnet")
        XCTAssertEqual(loaded.contextInstructions, "use pnpm")
    }
}

import XCTest
@testable import MultiharnessCore

@MainActor
final class QuickCreateTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-quickcreate-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() throws -> (AppEnvironment, WorkspaceStore, Project, ProviderRecord) {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultBaseBranch: "main"
        )
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(
            name: "Local", kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1",
            defaultModelId: "qwen2.5-7b"
        )
        try env.persistence.upsertProvider(prov)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        return (env, store, proj, prov)
    }

    func testResolveUsesProviderDefaultModelWhenNoOtherSources() throws {
        let (_, store, proj, prov) = try makeFixture()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [prov],
            globalDefault: nil
        )
        XCTAssertEqual(res.providerId, prov.id)
        XCTAssertEqual(res.modelId, "qwen2.5-7b")
        XCTAssertEqual(res.baseBranch, "main")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveFallsBackToGlobalDefaultWhenNoProvider() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)

        let globalProviderId = UUID()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [],
            globalDefault: (globalProviderId, "global-model")
        )
        // No providers configured → resolver can't surface providerId.
        // The global default's provider id is only useful if it's still in
        // the providers list, which it isn't here.
        XCTAssertNil(res.providerId)
        XCTAssertEqual(res.modelId, "global-model")
        XCTAssertEqual(res.missing, ["provider"])
    }

    func testResolveUsesGlobalDefaultProviderWhenItExistsInList() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let provA = ProviderRecord(name: "A", kind: .openaiCompatible, baseUrl: "http://a")
        let provB = ProviderRecord(name: "B", kind: .openaiCompatible, baseUrl: "http://b")
        try env.persistence.upsertProvider(provA)
        try env.persistence.upsertProvider(provB)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)

        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [provA, provB],
            globalDefault: (provB.id, "global-model")
        )
        // Project has no default, no inherit — global default's provider
        // wins over "first available" because it exists in the list.
        XCTAssertEqual(res.providerId, provB.id)
        XCTAssertEqual(res.modelId, "global-model")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveIgnoresGlobalDefaultProviderIfDeleted() throws {
        let (_, store, proj, prov) = try makeFixture()
        let staleId = UUID()
        let res = store.resolveQuickCreateInputs(
            project: proj,
            providers: [prov],
            globalDefault: (staleId, "global-model")
        )
        // Stale global provider id falls through to "first available".
        XCTAssertEqual(res.providerId, prov.id)
        // Model: provider's default wins over the global default because
        // the chain consults provider.defaultModelId first.
        XCTAssertEqual(res.modelId, "qwen2.5-7b")
        XCTAssertTrue(res.missing.isEmpty)
    }

    func testResolveReportsMissingModelWhenNothingResolves() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(
            name: "P", kind: .openaiCompatible,
            baseUrl: "http://p", defaultModelId: nil
        )
        try env.persistence.upsertProvider(prov)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        let res = store.resolveQuickCreateInputs(
            project: proj, providers: [prov], globalDefault: nil
        )
        XCTAssertEqual(res.providerId, prov.id)
        XCTAssertNil(res.modelId)
        XCTAssertEqual(res.missing, ["model"])
    }

    func testResolveBaseBranchPrefersProjectDefaultOverInheritedWorkspace() throws {
        let (env, store, proj, prov) = try makeFixture()
        // Simulate a prior workspace in this project whose baseBranch is
        // stale relative to the project default. Selecting it activates
        // the inherit path in resolveQuickCreateInputs.
        let prior = Workspace(
            projectId: proj.id,
            name: "prior",
            slug: "prior",
            branchName: "u/prior",
            baseBranch: "old-branch",
            worktreePath: "/tmp/prior",
            providerId: prov.id,
            modelId: "qwen2.5-7b"
        )
        try env.persistence.upsertWorkspace(prior)
        store.load(projectId: proj.id)
        store.selectedWorkspaceId = prior.id

        var updatedProject = proj
        updatedProject.defaultBaseBranch = "origin/nonprod"

        let res = store.resolveQuickCreateInputs(
            project: updatedProject, providers: [prov], globalDefault: nil
        )
        // Project default ("origin/nonprod") must win over prior workspace's
        // baseBranch ("old-branch"). User intent: "this project starts here."
        XCTAssertEqual(res.baseBranch, "origin/nonprod")
    }

    func testQuickCreateThrowsWhenResolutionMissing() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p", defaultBaseBranch: "main")
        try env.persistence.upsertProject(proj)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        XCTAssertThrowsError(try store.quickCreate(
            project: proj, providers: [], gitUserName: "u",
            globalDefault: nil
        )) { err in
            guard case WorkspaceStore.QuickCreateError.noProviderAvailable = err else {
                return XCTFail("expected noProviderAvailable, got \(err)")
            }
        }
    }
}

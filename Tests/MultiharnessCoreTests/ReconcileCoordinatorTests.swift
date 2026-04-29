import XCTest
@testable import MultiharnessCore
import MultiharnessClient

@MainActor
final class ReconcileCoordinatorTests: XCTestCase {
    func testPrepareRequiresEligibleWorkspaces() throws {
        let (env, app, ws) = try makeStores()
        let proj = try seedProject(app: app, persistence: env.persistence)
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        XCTAssertThrowsError(try coord.prepare(project: proj)) { err in
            guard case ReconcileError.noEligibleWorkspaces = err else {
                XCTFail("expected .noEligibleWorkspaces, got \(err)"); return
            }
        }
    }

    func testPreparePopulatesRowsForDoneAndInReview() throws {
        let (env, app, ws) = try makeStores()
        let proj = try seedProject(app: app, persistence: env.persistence)
        let prov = try seedProvider(app: app, persistence: env.persistence)
        for (state, name) in [
            (LifecycleState.done, "alpha"),
            (LifecycleState.inReview, "bravo"),
            (LifecycleState.inProgress, "charlie"),
        ] {
            let row = Workspace(
                projectId: proj.id, name: name, slug: name,
                branchName: "u/\(name)", baseBranch: "main",
                worktreePath: "/tmp/\(name)",
                lifecycleState: state, providerId: prov.id, modelId: "m"
            )
            try env.persistence.upsertWorkspace(row)
        }
        ws.load(projectId: proj.id)
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        try coord.prepare(project: proj)
        let names = coord.rows.map(\.name).sorted()
        XCTAssertEqual(names, ["alpha", "bravo"])
        XCTAssertTrue(coord.rows.allSatisfy { $0.state == .pending })
    }

    func testAbortIsCallable() throws {
        let (env, app, ws) = try makeStores()
        let coord = ReconcileCoordinator(env: env, appStore: app, workspaceStore: ws)
        coord.abort()
    }

    // MARK: - helpers

    private func makeStores() throws -> (AppEnvironment, AppStore, WorkspaceStore) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-reconcile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = try AppEnvironment(dataDir: dir)
        let app = AppStore(env: env)
        let ws = WorkspaceStore(env: env)
        return (env, app, ws)
    }

    private func seedProject(app: AppStore, persistence: PersistenceService) throws -> Project {
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p",
            defaultBaseBranch: "main",
            defaultProviderId: nil, defaultModelId: "model"
        )
        try persistence.upsertProject(proj)
        app.projects = try persistence.listProjects()
        app.selectedProjectId = proj.id
        return proj
    }

    private func seedProvider(app: AppStore, persistence: PersistenceService) throws -> ProviderRecord {
        let prov = ProviderRecord(
            name: "Local", kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1"
        )
        try persistence.upsertProvider(prov)
        app.providers = try persistence.listProviders()
        return prov
    }
}

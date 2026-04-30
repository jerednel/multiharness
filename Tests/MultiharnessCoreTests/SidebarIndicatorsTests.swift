import XCTest
@testable import MultiharnessCore

@MainActor
final class SidebarIndicatorsTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-sidebar-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFixture() throws -> (env: AppEnvironment, ws: WorkspaceStore, workspace: Workspace) {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try env.persistence.upsertProject(proj)
        let prov = ProviderRecord(name: "Local", kind: .openaiCompatible, baseUrl: "http://localhost:1234/v1")
        try env.persistence.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id, name: "W", slug: "w",
            branchName: "u/w", baseBranch: "main",
            worktreePath: "/tmp/wt",
            providerId: prov.id, modelId: "m"
        )
        try env.persistence.upsertWorkspace(ws)
        let store = WorkspaceStore(env: env)
        store.load(projectId: proj.id)
        return (env, store, ws)
    }

    private func writeJsonl(_ env: AppEnvironment, workspaceId: UUID, agentEndMs: Int64) throws {
        let path = env.persistence.messagesPath(workspaceId: workspaceId)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let line = #"{"seq":0,"ts":\#(agentEndMs),"event":{"type":"agent_end","messages":[]}}"#
        try (line + "\n").data(using: .utf8)!.write(to: path)
    }

    func testUnseenIsTrueWhenAssistantNewerThanLastViewed() throws {
        let (env, store, ws) = try makeFixture()
        // Backfill puts last_viewed_at at "now"; force it earlier.
        try env.persistence.db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = 0 WHERE id = ?;"
        ) { $0.bind(1, ws.id.uuidString) }
        try writeJsonl(env, workspaceId: ws.id, agentEndMs: 1_000)
        store.load(projectId: ws.projectId)
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertTrue(store.unseen(updated))
    }

    func testUnseenIsFalseAfterMarkViewed() throws {
        let (env, store, ws) = try makeFixture()
        try env.persistence.db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = 0 WHERE id = ?;"
        ) { $0.bind(1, ws.id.uuidString) }
        try writeJsonl(env, workspaceId: ws.id, agentEndMs: 1_000)
        store.load(projectId: ws.projectId)
        store.markViewed(ws.id)
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertFalse(store.unseen(updated))
    }

    func testUnseenIsFalseWhenNoAssistantActivity() throws {
        let (_, store, ws) = try makeFixture()
        // No JSONL written.
        let updated = store.workspaces.first { $0.id == ws.id }!
        XCTAssertFalse(store.unseen(updated))
    }

    func testRecordAssistantEndFlipsUnseen() throws {
        let (env, store, ws) = try makeFixture()
        try env.persistence.db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = 0 WHERE id = ?;"
        ) { $0.bind(1, ws.id.uuidString) }
        store.load(projectId: ws.projectId)
        let initial = store.workspaces.first { $0.id == ws.id }!
        XCTAssertFalse(store.unseen(initial))
        store.recordAssistantEnd(workspaceId: ws.id)
        XCTAssertTrue(store.unseen(initial))
    }
}

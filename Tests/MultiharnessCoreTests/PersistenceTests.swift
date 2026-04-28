import XCTest
@testable import MultiharnessCore

final class PersistenceTests: XCTestCase {
    func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testProjectRoundtrip() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let p = Project(
            name: "Test Project",
            slug: "test-project",
            repoPath: "/tmp/repo",
            defaultBaseBranch: "main"
        )
        try svc.upsertProject(p)
        let loaded = try svc.listProjects()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].name, "Test Project")
        XCTAssertEqual(loaded[0].slug, "test-project")
    }

    func testProviderRoundtrip() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let prov = ProviderRecord(
            name: "OpenRouter",
            kind: .piKnown,
            piProvider: "openrouter",
            keychainAccount: "openrouter-default"
        )
        try svc.upsertProvider(prov)
        let loaded = try svc.listProviders()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].kind, .piKnown)
        XCTAssertEqual(loaded[0].piProvider, "openrouter")
    }

    func testWorkspaceLifecycleRoundtrip() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(
            name: "Local",
            kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1"
        )
        try svc.upsertProvider(prov)
        let ws = Workspace(
            projectId: proj.id,
            name: "Feature",
            slug: "feature",
            branchName: "user/feature",
            baseBranch: "main",
            worktreePath: "/tmp/wt",
            lifecycleState: .inReview,
            providerId: prov.id,
            modelId: "qwen2.5-7b-instruct"
        )
        try svc.upsertWorkspace(ws)
        let loaded = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].lifecycleState, .inReview)
    }

    func testSlugify() {
        XCTAssertEqual(slugify("Hello World"), "hello-world")
        XCTAssertEqual(slugify("Multi  Spaces"), "multi-spaces")
        XCTAssertEqual(slugify("Weird!@#chars"), "weird-chars")
        XCTAssertEqual(slugify(""), "item")
    }
}

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

    func testBuildModeRoundtripsForProjectAndWorkspace() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(
            name: "P", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed
        )
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
            providerId: prov.id,
            modelId: "qwen2.5-7b-instruct",
            buildMode: .primary
        )
        try svc.upsertWorkspace(ws)
        let projects = try svc.listProjects()
        XCTAssertEqual(projects.first(where: { $0.id == proj.id })?.defaultBuildMode, .shadowed)
        let workspaces = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertEqual(workspaces.first?.buildMode, .primary)
    }

    func testNameSourceRoundtrip() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
        let proj = Project(name: "P", slug: "p", repoPath: "/tmp/p")
        try svc.upsertProject(proj)
        let prov = ProviderRecord(name: "L", kind: .openaiCompatible, baseUrl: "http://x")
        try svc.upsertProvider(prov)
        // Default round-trips as .random.
        let randomWs = Workspace(
            projectId: proj.id,
            name: "Lucky Otter", slug: "lucky-otter",
            branchName: "u/lucky-otter", baseBranch: "main", worktreePath: "/tmp/wa",
            providerId: prov.id, modelId: "m"
        )
        try svc.upsertWorkspace(randomWs)
        // Explicit .named round-trips as .named.
        let namedWs = Workspace(
            projectId: proj.id,
            name: "Manual Title", slug: "manual-title",
            branchName: "u/manual-title", baseBranch: "main", worktreePath: "/tmp/wb",
            providerId: prov.id, modelId: "m",
            nameSource: .named
        )
        try svc.upsertWorkspace(namedWs)
        let loaded = try svc.listWorkspaces(projectId: proj.id)
        let byId = Dictionary(uniqueKeysWithValues: loaded.map { ($0.id, $0) })
        XCTAssertEqual(byId[randomWs.id]?.nameSource, .random)
        XCTAssertEqual(byId[namedWs.id]?.nameSource, .named)
    }

    func testNullBuildModeStaysNull() throws {
        let dir = try tempDir()
        let svc = try PersistenceService(dataDir: dir)
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
        let loaded = try svc.listWorkspaces(projectId: proj.id)
        XCTAssertNil(loaded.first?.buildMode)
        XCTAssertNil(try svc.listProjects().first(where: { $0.id == proj.id })?.defaultBuildMode)
    }
}

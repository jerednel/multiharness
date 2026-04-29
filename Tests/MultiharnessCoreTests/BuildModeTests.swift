import XCTest
import MultiharnessClient

final class BuildModeTests: XCTestCase {
    func testEffectiveBuildModeDefaultsToPrimary() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p")
        let ws = workspace(projectId: proj.id, mode: nil)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .primary)
    }

    func testEffectiveBuildModeUsesProjectDefault() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed)
        let ws = workspace(projectId: proj.id, mode: nil)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .shadowed)
    }

    func testWorkspaceOverridesProjectDefault() {
        let proj = Project(name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed)
        let ws = workspace(projectId: proj.id, mode: .primary)
        XCTAssertEqual(ws.effectiveBuildMode(in: proj), .primary)
    }

    func testCodableRoundtrip() throws {
        let original = Project(
            name: "p", slug: "p", repoPath: "/tmp/p", defaultBuildMode: .shadowed
        )
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Project.self, from: data)
        XCTAssertEqual(restored.defaultBuildMode, .shadowed)
    }

    private func workspace(projectId: UUID, mode: BuildMode?) -> Workspace {
        Workspace(
            projectId: projectId,
            name: "w",
            slug: "w",
            branchName: "u/w",
            baseBranch: "main",
            worktreePath: "/tmp/w",
            providerId: UUID(),
            modelId: "m",
            buildMode: mode
        )
    }
}

import XCTest
import MultiharnessClient

final class QaSelectionFallbackTests: XCTestCase {
    func testReturnsNilNilWhenNeitherSet() {
        let proj = project()
        let ws = workspace(in: proj, providerId: nil, modelId: nil)
        let sel = ws.qaPopoverInitialSelection(in: proj)
        XCTAssertNil(sel.providerId)
        XCTAssertNil(sel.modelId)
    }

    func testFallsBackToProjectDefaultsWhenWorkspaceUnset() {
        let pid = UUID()
        let proj = project(providerId: pid, modelId: "claude-3-7-sonnet")
        let ws = workspace(in: proj, providerId: nil, modelId: nil)
        let sel = ws.qaPopoverInitialSelection(in: proj)
        XCTAssertEqual(sel.providerId, pid)
        XCTAssertEqual(sel.modelId, "claude-3-7-sonnet")
    }

    func testWorkspaceValuesWinOverProjectDefaults() {
        let projPid = UUID()
        let wsPid = UUID()
        let proj = project(providerId: projPid, modelId: "claude-3-7-sonnet")
        let ws = workspace(in: proj, providerId: wsPid, modelId: "gpt-5-mini")
        let sel = ws.qaPopoverInitialSelection(in: proj)
        XCTAssertEqual(sel.providerId, wsPid)
        XCTAssertEqual(sel.modelId, "gpt-5-mini")
    }

    func testProviderAndModelFallbackIndependently() {
        // Workspace overrides only the provider — model still falls back.
        let projPid = UUID()
        let wsPid = UUID()
        let proj = project(providerId: projPid, modelId: "claude-3-7-sonnet")
        let ws = workspace(in: proj, providerId: wsPid, modelId: nil)
        let sel = ws.qaPopoverInitialSelection(in: proj)
        XCTAssertEqual(sel.providerId, wsPid)
        XCTAssertEqual(sel.modelId, "claude-3-7-sonnet")
    }

    func testSelectionIsIndependentOfEnabledFlag() {
        // Model picks must survive toggle state — opt-out should not
        // strip the pre-selected QA model.
        let pid = UUID()
        let proj = project(providerId: pid, modelId: "claude-3-7-sonnet")
        let optedOut = workspace(in: proj, providerId: nil, modelId: nil, enabled: false)
        let sel = optedOut.qaPopoverInitialSelection(in: proj)
        XCTAssertEqual(sel.providerId, pid)
        XCTAssertEqual(sel.modelId, "claude-3-7-sonnet")
    }

    // MARK: - Helpers

    private func project(providerId: UUID? = nil, modelId: String? = nil) -> Project {
        Project(
            name: "p", slug: "p", repoPath: "/tmp/p",
            defaultQaProviderId: providerId,
            defaultQaModelId: modelId
        )
    }

    private func workspace(
        in proj: Project,
        providerId: UUID?,
        modelId: String?,
        enabled: Bool? = nil
    ) -> Workspace {
        Workspace(
            projectId: proj.id,
            name: "w", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: UUID(), modelId: "primary-m",
            qaEnabled: enabled,
            qaProviderId: providerId,
            qaModelId: modelId
        )
    }
}

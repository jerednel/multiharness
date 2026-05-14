import XCTest
import MultiharnessClient

final class QaInheritanceTests: XCTestCase {
    // MARK: - effectiveQaEnabled

    func testEnabledFallsBackToProjectDefaultWhenNoOverride() {
        let projOn = project(defaultEnabled: true)
        let projOff = project(defaultEnabled: false)
        XCTAssertTrue(workspace(in: projOn, override: nil).effectiveQaEnabled(in: projOn))
        XCTAssertFalse(workspace(in: projOff, override: nil).effectiveQaEnabled(in: projOff))
    }

    func testExplicitOptInBeatsProjectDefaultOff() {
        let proj = project(defaultEnabled: false)
        let ws = workspace(in: proj, override: true)
        XCTAssertTrue(ws.effectiveQaEnabled(in: proj))
    }

    func testExplicitOptOutBeatsProjectDefaultOn() {
        let proj = project(defaultEnabled: true)
        let ws = workspace(in: proj, override: false)
        XCTAssertFalse(ws.effectiveQaEnabled(in: proj))
    }

    // MARK: - qaEnabledIsOverridden

    func testOverriddenIsFalseWhenWorkspaceNil() {
        let proj = project(defaultEnabled: true)
        XCTAssertFalse(workspace(in: proj, override: nil).qaEnabledIsOverridden(in: proj))
    }

    func testOverriddenIsTrueWhenWorkspaceCarriesAnyExplicitValue() {
        // The spec is explicit: ANY non-nil workspace value counts as an
        // override, even when it happens to match the project default. The
        // user's deliberate decision shouldn't silently evaporate just
        // because the project default later changes to match.
        let projOn = project(defaultEnabled: true)
        let projOff = project(defaultEnabled: false)
        XCTAssertTrue(workspace(in: projOn, override: true).qaEnabledIsOverridden(in: projOn))
        XCTAssertTrue(workspace(in: projOff, override: false).qaEnabledIsOverridden(in: projOff))
        XCTAssertTrue(workspace(in: projOn, override: false).qaEnabledIsOverridden(in: projOn))
        XCTAssertTrue(workspace(in: projOff, override: true).qaEnabledIsOverridden(in: projOff))
    }

    // MARK: - Helpers

    private func project(defaultEnabled: Bool) -> Project {
        Project(
            name: "p", slug: "p", repoPath: "/tmp/p",
            defaultQaEnabled: defaultEnabled
        )
    }

    private func workspace(in proj: Project, override: Bool?) -> Workspace {
        Workspace(
            projectId: proj.id,
            name: "w", slug: "w",
            branchName: "u/w", baseBranch: "main", worktreePath: "/tmp/w",
            providerId: UUID(), modelId: "m",
            qaEnabled: override
        )
    }
}

import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class QaAutoApplyPromptBuilderTests: XCTestCase {
    private func finding(
        severity: QaFinding.Severity = .blocker,
        file: String? = nil,
        line: Int? = nil,
        message: String
    ) -> QaFinding {
        QaFinding(severity: severity, file: file, line: line, message: message)
    }

    func testIncludesVerdictAndSummaryHeader() {
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "Two regressions in math.swift.",
            findings: [
                finding(file: "src/math.swift", line: 12, message: "div() returns wrong result on zero"),
            ],
            cycleIndex: 1,
            cycleCap: 3
        )
        XCTAssertTrue(out.contains("blocking issues"))
        XCTAssertTrue(out.contains("Two regressions in math.swift."))
        XCTAssertTrue(out.contains("src/math.swift:12 — div() returns wrong result on zero"))
        XCTAssertTrue(out.contains("Please fix the blocking findings"))
    }

    func testFiltersOutNonBlockerFindings() {
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "",
            findings: [
                finding(severity: .blocker, file: "a.swift", message: "Hard fail"),
                finding(severity: .info, file: "b.swift", message: "Nit: doc typo"),
                finding(severity: .warning, file: "c.swift", message: "Style"),
            ],
            cycleIndex: 1,
            cycleCap: 3
        )
        XCTAssertTrue(out.contains("Hard fail"))
        XCTAssertFalse(out.contains("Nit: doc typo"))
        XCTAssertFalse(out.contains("Style"))
    }

    func testAnnouncesFinalCycle() {
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "",
            findings: [finding(message: "x")],
            cycleIndex: 3,
            cycleCap: 3
        )
        XCTAssertTrue(out.contains("final auto-QA cycle"))
    }

    func testShowsRemainingCyclesEarlyInLoop() {
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "",
            findings: [finding(message: "x")],
            cycleIndex: 1,
            cycleCap: 3
        )
        XCTAssertTrue(out.contains("2 cycles remaining"))
    }

    func testFindingsWithoutFileStillRender() {
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "",
            findings: [finding(message: "Race condition somewhere in the worker pool")],
            cycleIndex: 1,
            cycleCap: 3
        )
        XCTAssertTrue(out.contains("Race condition somewhere"))
    }

    func testTruncatesLongMessages() {
        let long = String(repeating: "x", count: 800)
        let out = QaAutoApplyPromptBuilder.build(
            verdict: .blockingIssues,
            summary: "",
            findings: [finding(file: "f.swift", line: 1, message: long)],
            cycleIndex: 1,
            cycleCap: 3
        )
        // 600-char cap + "…"
        XCTAssertFalse(out.contains(long))
        XCTAssertTrue(out.contains("…"))
    }
}

/// Inheritance behavior for the new `qa_auto_apply` flag — mirrors the
/// pattern in `QaInheritanceTests` for `qa_enabled`.
final class QaAutoApplyInheritanceTests: XCTestCase {
    private func makeProject(defaultAutoApply: Bool) -> Project {
        Project(name: "p", slug: "p", repoPath: "/tmp", defaultQaAutoApply: defaultAutoApply)
    }

    private func makeWorkspace(projectId: UUID, autoApply: Bool? = nil) -> Workspace {
        Workspace(
            projectId: projectId,
            name: "w", slug: "w",
            branchName: "b", baseBranch: "main", worktreePath: "/tmp/wt",
            providerId: UUID(), modelId: "x",
            qaAutoApply: autoApply
        )
    }

    func testWorkspaceNilInheritsProjectDefaultOn() {
        let p = makeProject(defaultAutoApply: true)
        let w = makeWorkspace(projectId: p.id)
        XCTAssertTrue(w.effectiveQaAutoApply(in: p))
    }

    func testWorkspaceNilInheritsProjectDefaultOff() {
        let p = makeProject(defaultAutoApply: false)
        let w = makeWorkspace(projectId: p.id)
        XCTAssertFalse(w.effectiveQaAutoApply(in: p))
    }

    func testExplicitWorkspaceTrueOverridesProjectOff() {
        let p = makeProject(defaultAutoApply: false)
        let w = makeWorkspace(projectId: p.id, autoApply: true)
        XCTAssertTrue(w.effectiveQaAutoApply(in: p))
    }

    func testExplicitWorkspaceFalseOverridesProjectOn() {
        let p = makeProject(defaultAutoApply: true)
        let w = makeWorkspace(projectId: p.id, autoApply: false)
        XCTAssertFalse(w.effectiveQaAutoApply(in: p))
    }
}

import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class QaFirstMessageBuilderTests: XCTestCase {
    // MARK: - Inputs assembly

    func testEmitsBranchAndBaseHeader() {
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "u/feat",
            baseBranch: "main",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            diffVsBase: ""
        ))
        XCTAssertTrue(out.contains("Branch: u/feat"))
        XCTAssertTrue(out.contains("Base:   main"))
    }

    func testIncludesLastUserAndAssistantWhenPresent() {
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "b", baseBranch: "main",
            lastUserPrompt: "add div() to math.ts",
            lastAssistantMessage: "Added div(a, b) and a test.",
            diffVsBase: "+ small diff"
        ))
        XCTAssertTrue(out.contains("add div() to math.ts"))
        XCTAssertTrue(out.contains("Added div(a, b) and a test."))
    }

    func testOmitsSectionHeadersWhenInputsAreNilOrEmpty() {
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "b", baseBranch: "main",
            lastUserPrompt: nil,
            lastAssistantMessage: "   ",
            diffVsBase: ""
        ))
        XCTAssertFalse(out.contains("Most recent user request"))
        XCTAssertFalse(out.contains("Primary agent's final summary"))
    }

    func testEmptyDiffRendersExplicitMessage() {
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "b", baseBranch: "main",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            diffVsBase: ""
        ))
        XCTAssertTrue(out.contains("no diff"))
    }

    func testAlwaysClosesWithPleaseReviewSentinel() {
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "b", baseBranch: "main",
            lastUserPrompt: nil,
            lastAssistantMessage: nil,
            diffVsBase: ""
        ))
        XCTAssertTrue(out.hasSuffix("Please review."))
    }

    // MARK: - Diff truncation

    func testDiffsUnderCapPassThroughUntouched() {
        let small = "+++ b/a.txt\n@@ -1 +1 @@\n-foo\n+bar\n"
        let (body, omitted) = QaFirstMessageBuilder.truncateDiff(small)
        XCTAssertEqual(body, small)
        XCTAssertFalse(omitted)
    }

    func testDiffsOverCapTruncateAndFlag() {
        // Build a diff comfortably over the cap with line structure.
        let line = "+ \(String(repeating: "x", count: 80))\n"
        let pad = String(repeating: line, count: 1000)  // ~82 KB
        XCTAssertGreaterThan(pad.count, QaFirstMessageBuilder.diffCharacterCap)
        let (body, omitted) = QaFirstMessageBuilder.truncateDiff(pad)
        XCTAssertTrue(omitted)
        XCTAssertLessThanOrEqual(body.count, QaFirstMessageBuilder.diffCharacterCap)
        // Truncation should respect line boundaries — the body must end
        // on a newline (we never want to dump a half-line into the
        // reviewer's seed message).
        XCTAssertTrue(body.hasSuffix("\n"))
    }

    func testTruncatedMessageMentionsTruncation() {
        let pad = String(repeating: "+x\n", count: 30_000)
        let out = QaFirstMessageBuilder.build(.init(
            branchName: "b", baseBranch: "main",
            lastUserPrompt: nil, lastAssistantMessage: nil,
            diffVsBase: pad
        ))
        XCTAssertTrue(out.contains("truncated"))
        XCTAssertTrue(out.contains("read_file"))
    }

    // MARK: - Last-turn extraction

    func testLastUserTextPicksTheMostRecentUserTurn() {
        let turns: [ConversationTurn] = [
            ConversationTurn(role: .user, text: "old"),
            ConversationTurn(role: .assistant, text: "ok"),
            ConversationTurn(role: .user, text: "newer"),
            ConversationTurn(role: .assistant, text: "done"),
        ]
        XCTAssertEqual(QaFirstMessageBuilder.lastUserText(in: turns), "newer")
    }

    func testLastUserTextReturnsNilWithNoUserTurns() {
        XCTAssertNil(QaFirstMessageBuilder.lastUserText(in: [
            ConversationTurn(role: .assistant, text: "x"),
        ]))
    }

    func testLastAssistantTextPicksMostRecentAssistantTurn() {
        let turns: [ConversationTurn] = [
            ConversationTurn(role: .assistant, text: "first"),
            ConversationTurn(role: .tool, text: "tool result"),
            ConversationTurn(role: .assistant, text: "second"),
            ConversationTurn(role: .qaFindings, text: "qa summary"),
        ]
        // QA findings turns must NOT be picked — feeding a QA verdict
        // back as the "primary agent's summary" would loop.
        XCTAssertEqual(
            QaFirstMessageBuilder.lastAssistantText(in: turns),
            "second"
        )
    }

    func testLastAssistantTextSkipsEmptyAssistantTurns() {
        let turns: [ConversationTurn] = [
            ConversationTurn(role: .assistant, text: "real"),
            ConversationTurn(role: .assistant, text: ""),
        ]
        XCTAssertEqual(
            QaFirstMessageBuilder.lastAssistantText(in: turns),
            "real"
        )
    }
}

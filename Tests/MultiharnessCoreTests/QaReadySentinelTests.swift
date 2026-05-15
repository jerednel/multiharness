import XCTest
@testable import MultiharnessCore
import MultiharnessClient

final class QaReadySentinelTests: XCTestCase {
    // MARK: - Token detection

    func testIsPresentDetectsToken() {
        XCTAssertTrue(QaReadySentinel.isPresent(in: "All done.\n<<MULTIHARNESS_QA_READY>>"))
    }

    func testIsPresentFalseWhenAbsent() {
        XCTAssertFalse(QaReadySentinel.isPresent(in: "All done. Tests pass."))
    }

    // MARK: - Stripping

    func testStrippedRemovesTokenOnItsOwnLine() {
        let cleaned = QaReadySentinel.stripped(
            from: "Implemented div().\n\n<<MULTIHARNESS_QA_READY>>\n"
        )
        XCTAssertEqual(cleaned, "Implemented div().")
    }

    func testStrippedRemovesTokenAtEndWithoutNewline() {
        let cleaned = QaReadySentinel.stripped(
            from: "Done. <<MULTIHARNESS_QA_READY>>"
        )
        XCTAssertEqual(cleaned, "Done.")
    }

    func testStrippedHandlesMultipleOccurrences() {
        let cleaned = QaReadySentinel.stripped(
            from: "<<MULTIHARNESS_QA_READY>>\nfoo\n<<MULTIHARNESS_QA_READY>>"
        )
        XCTAssertEqual(cleaned, "foo")
    }

    func testStrippedPassesThroughUnchangedWhenNoToken() {
        XCTAssertEqual(QaReadySentinel.stripped(from: "no token"), "no token")
    }

    // MARK: - QA first-message scrubbing

    func testLastAssistantTextStripsSentinel() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                role: .assistant,
                text: "Done.\n<<MULTIHARNESS_QA_READY>>",
                groupId: "g1"
            )
        ]
        let text = QaFirstMessageBuilder.lastAssistantText(in: turns)
        XCTAssertEqual(text, "Done.")
    }

    func testLastAssistantTextReturnsNilWhenSentinelOnlyContent() {
        let turns: [ConversationTurn] = [
            ConversationTurn(
                role: .assistant,
                text: "<<MULTIHARNESS_QA_READY>>",
                groupId: "g1"
            )
        ]
        XCTAssertNil(QaFirstMessageBuilder.lastAssistantText(in: turns))
    }
}

/// Behavioral tests for `AgentStore.consumeQaReadySentinel()` — the
/// helper App.swift uses on `agent_end` to decide whether to auto-fire QA.
@MainActor
final class AgentStoreSentinelConsumeTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testConsumeReturnsFalseWhenNoAssistantTurns() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let store = AgentStore(env: env, workspaceId: UUID())
        XCTAssertFalse(store.consumeQaReadySentinel())
    }

    func testConsumeReturnsFalseWhenLastAssistantHasNoToken() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let store = AgentStore(env: env, workspaceId: UUID())
        store.turns.append(ConversationTurn(role: .assistant, text: "All done.", groupId: "g1"))
        XCTAssertFalse(store.consumeQaReadySentinel())
        XCTAssertEqual(store.turns.last?.text, "All done.")
    }

    func testConsumeStripsTokenAndReturnsTrueOnBuildTurn() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let store = AgentStore(env: env, workspaceId: UUID())
        store.groupKinds["g1"] = .build
        store.turns.append(ConversationTurn(
            role: .assistant,
            text: "All done.\n<<MULTIHARNESS_QA_READY>>",
            groupId: "g1"
        ))
        XCTAssertTrue(store.consumeQaReadySentinel())
        XCTAssertEqual(store.turns.last?.text, "All done.")
    }

    func testConsumeReturnsFalseForQaGroupEvenWithToken() throws {
        // Defensive: QA agent's prompt never includes the addendum, but
        // if something ever made it into a QA-tagged turn we must not
        // recursively auto-fire QA.
        let env = try AppEnvironment(dataDir: tempDir())
        let store = AgentStore(env: env, workspaceId: UUID())
        store.groupKinds["g1"] = .qa
        store.turns.append(ConversationTurn(
            role: .assistant,
            text: "<<MULTIHARNESS_QA_READY>>",
            groupId: "g1"
        ))
        XCTAssertFalse(store.consumeQaReadySentinel())
    }
}

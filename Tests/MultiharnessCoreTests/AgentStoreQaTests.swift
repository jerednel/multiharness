import XCTest
@testable import MultiharnessCore
import MultiharnessClient

/// Cover the QA-specific branches of `AgentStore.handleEvent` and
/// `AgentStore.loadHistory`. Avoids spinning up a sidecar by writing
/// raw JSONL directly to disk and observing what the store
/// reconstructs.
@MainActor
final class AgentStoreQaTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mh-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeJsonl(_ lines: [String], for wsId: UUID, in svc: PersistenceService) throws {
        let path = svc.messagesPath(workspaceId: wsId)
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!.write(to: path)
    }

    // MARK: - handleEvent (live path)

    func testAgentStartWithoutKindTagsGroupAsBuild() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let wsId = UUID()
        let store = AgentStore(env: env, workspaceId: wsId)
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "agent_start",
            payload: [:]
        ))
        XCTAssertEqual(store.lastGroupKind, .build)
    }

    func testAgentStartWithKindQaTagsGroupAsQa() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let wsId = UUID()
        let store = AgentStore(env: env, workspaceId: wsId)
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "agent_start",
            payload: ["kind": "qa"]
        ))
        XCTAssertEqual(store.lastGroupKind, .qa)
    }

    func testQaFindingsAppendsStructuredTurn() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let wsId = UUID()
        let store = AgentStore(env: env, workspaceId: wsId)
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "agent_start",
            payload: ["kind": "qa"]
        ))
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "qa_findings",
            payload: [
                "verdict": "minor_issues",
                "summary": "Looks good but missing a test.",
                "findings": [
                    [
                        "severity": "warning",
                        "file": "src/foo.swift",
                        "line": 42,
                        "message": "TODO left in.",
                    ],
                ],
            ]
        ))
        let qaTurns = store.turns.filter { $0.role == .qaFindings }
        XCTAssertEqual(qaTurns.count, 1)
        let t = qaTurns.first!
        XCTAssertEqual(t.qaVerdict, .minorIssues)
        XCTAssertEqual(t.text, "Looks good but missing a test.")
        XCTAssertEqual(t.qaFindings.count, 1)
        XCTAssertEqual(t.qaFindings.first?.file, "src/foo.swift")
        XCTAssertEqual(t.qaFindings.first?.line, 42)
        XCTAssertEqual(t.qaFindings.first?.severity, .warning)
    }

    func testQaFindingsTurnInheritsCurrentGroupId() throws {
        // The findings card must collapse with the rest of the QA run
        // (read_file, grep, etc.), so its groupId must match the
        // currently-streaming run.
        let env = try AppEnvironment(dataDir: tempDir())
        let wsId = UUID()
        let store = AgentStore(env: env, workspaceId: wsId)
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "agent_start",
            payload: ["kind": "qa"]
        ))
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "qa_findings",
            payload: ["verdict": "pass", "summary": "all good"]
        ))
        let turn = store.turns.first(where: { $0.role == .qaFindings })!
        // Live groups use the "live-<n>" prefix.
        XCTAssertNotNil(turn.groupId)
        XCTAssertTrue(turn.groupId!.hasPrefix("live-"))
        // And the store knows that group is a QA group.
        XCTAssertEqual(store.groupKind(for: turn.groupId), .qa)
    }

    func testQaFindingsHandlesMissingFindingsArray() throws {
        // Defensive — agents sometimes omit optional fields entirely.
        let env = try AppEnvironment(dataDir: tempDir())
        let wsId = UUID()
        let store = AgentStore(env: env, workspaceId: wsId)
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "agent_start",
            payload: ["kind": "qa"]
        ))
        store.handleEvent(AgentEventEnvelope(
            workspaceId: wsId.uuidString,
            type: "qa_findings",
            payload: ["verdict": "pass", "summary": "all good"]
        ))
        let t = store.turns.first(where: { $0.role == .qaFindings })!
        XCTAssertEqual(t.qaFindings, [])
        XCTAssertEqual(t.qaVerdict, .pass)
    }

    func testGroupKindAccessorFallsBackToBuildForUnknownIds() throws {
        let env = try AppEnvironment(dataDir: tempDir())
        let store = AgentStore(env: env, workspaceId: UUID())
        XCTAssertEqual(store.groupKind(for: nil), .build)
        XCTAssertEqual(store.groupKind(for: "no-such-group"), .build)
    }

    // MARK: - loadHistory (JSONL rehydration)

    func testLoadHistoryReconstructsQaFindingsCard() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let wsId = UUID()
        // Single QA run: agent_start (qa-tagged) → tool_execution_start/end
        // (read_file) → qa_findings → agent_end.
        let lines = [
            #"{"seq":0,"ts":1000,"event":{"type":"agent_start","kind":"qa"}}"#,
            #"{"seq":1,"ts":1500,"event":{"type":"tool_execution_start","toolName":"read_file","args":{"description":"Read main.ts"}}}"#,
            #"{"seq":2,"ts":1800,"event":{"type":"tool_execution_end","result":{"content":[{"text":"file body"}]}}}"#,
            #"{"seq":3,"ts":2000,"event":{"type":"qa_findings","verdict":"minor_issues","summary":"Has a typo.","findings":[{"severity":"info","message":"line 4 typo"}]}}"#,
            #"{"seq":4,"ts":2500,"event":{"type":"agent_end","messages":[]}}"#,
        ]
        try writeJsonl(lines, for: wsId, in: env.persistence)
        let store = AgentStore(env: env, workspaceId: wsId)
        // The qaFindings card should appear in the rehydrated turn list.
        let qa = store.turns.filter { $0.role == .qaFindings }
        XCTAssertEqual(qa.count, 1)
        XCTAssertEqual(qa.first?.qaVerdict, .minorIssues)
        XCTAssertEqual(qa.first?.qaFindings.count, 1)
        XCTAssertEqual(qa.first?.qaFindings.first?.message, "line 4 typo")
        // And the group it lives in should be tagged as qa.
        let groupId = qa.first?.groupId
        XCTAssertNotNil(groupId)
        XCTAssertEqual(store.groupKind(for: groupId), .qa)
        // lastGroupKind is set from the last persisted agent_start.
        XCTAssertEqual(store.lastGroupKind, .qa)
    }

    func testLoadHistoryDistinguishesQaFromBuildGroupsWhenBothPresent() throws {
        let dir = try tempDir()
        let env = try AppEnvironment(dataDir: dir)
        let wsId = UUID()
        let lines = [
            // Build run.
            #"{"seq":0,"ts":1000,"event":{"type":"agent_start"}}"#,
            #"{"seq":1,"ts":1500,"event":{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}}"#,
            #"{"seq":2,"ts":1800,"event":{"type":"agent_end","messages":[]}}"#,
            // QA run.
            #"{"seq":3,"ts":2000,"event":{"type":"agent_start","kind":"qa"}}"#,
            #"{"seq":4,"ts":2500,"event":{"type":"qa_findings","verdict":"pass","summary":"clean"}}"#,
            #"{"seq":5,"ts":3000,"event":{"type":"agent_end","messages":[]}}"#,
        ]
        try writeJsonl(lines, for: wsId, in: env.persistence)
        let store = AgentStore(env: env, workspaceId: wsId)
        // Two distinct groups should exist with different kinds.
        let groupIds = Set(store.turns.compactMap { $0.groupId })
        XCTAssertEqual(groupIds.count, 2)
        let kinds = Set(groupIds.map { store.groupKind(for: $0) })
        XCTAssertEqual(kinds, [.build, .qa])
        // Most recent run was QA.
        XCTAssertEqual(store.lastGroupKind, .qa)
    }
}

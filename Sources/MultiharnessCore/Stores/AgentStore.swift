import Foundation
import Observation
import MultiharnessClient

@MainActor
@Observable
public final class AgentStore {
    public var workspaceId: UUID
    public var turns: [ConversationTurn] = []
    public var isStreaming: Bool = false
    public var connectionState: String = "disconnected"
    public var lastError: String?
    /// Per-groupId kind annotation, populated when an `agent_start`
    /// carries `kind: "qa"` (or rehydrated from the same field in the
    /// JSONL). Lets the UI theme the disclosure header without
    /// putting QA-specific fields on every `ConversationTurn`.
    public var groupKinds: [String: GroupKind] = [:]
    /// The kind of the most recent agent run. Mirrors `groupKinds` for
    /// the latest live group; kept around after the run ends so the
    /// composer's "🔍 QA running…" label can flip back to idle when
    /// `isStreaming` drops to false. See spec §12 ("Distinguishing
    /// primary streaming from QA streaming in the UI").
    public var lastGroupKind: GroupKind?

    private let env: AppEnvironment
    private weak var control: ControlClient?

    public init(env: AppEnvironment, workspaceId: UUID) {
        self.env = env
        self.workspaceId = workspaceId
        loadHistory()
    }

    /// Look up the kind of the group a turn belongs to. Returns `.build`
    /// for any group that didn't explicitly register as something else.
    public func groupKind(for groupId: String?) -> GroupKind {
        guard let id = groupId else { return .build }
        return groupKinds[id] ?? .build
    }

    /// Replay the persisted JSONL message log and reconstruct the visible turn
    /// list. Called once at construction so the user sees their prior
    /// conversation when they reopen a workspace (or after a sidecar crash).
    public func loadHistory() {
        let path = env.persistence.messagesPath(workspaceId: workspaceId)
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [ConversationTurn] = []
        var groupId: String?
        var groupCounter = 0
        var rehydratedKinds: [String: GroupKind] = [:]
        var rehydratedLastKind: GroupKind?
        // Re-derived from agent_start/agent_end markers in the JSONL so
        // history rehydration produces the same group structure as the
        // live event stream.
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = obj["event"] as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch type {
            case "agent_start":
                groupCounter += 1
                let gid = "g\(groupCounter)"
                groupId = gid
                let kind = (event["kind"] as? String) == "qa" ? GroupKind.qa : .build
                rehydratedKinds[gid] = kind
                rehydratedLastKind = kind
            case "agent_end":
                groupId = nil
            case "message_end":
                guard let msg = event["message"] as? [String: Any],
                      let role = msg["role"] as? String
                else { continue }
                let text = Self.extractText(msg["content"])
                let images = role == "user" ? Self.extractImages(msg["content"]) : []
                switch role {
                case "user":
                    // Preserve image-only user turns (no caption) — empty
                    // text alone is no longer a reason to skip.
                    if !text.isEmpty || !images.isEmpty {
                        // User turns are added before agent_start in the live
                        // flow, so they have no groupId. Persisted user
                        // message_end events arrive inside the active group;
                        // strip the groupId here so loaded history matches
                        // the live structure.
                        loaded.append(ConversationTurn(
                            role: .user,
                            text: text,
                            images: images
                        ))
                    }
                case "assistant":
                    if !text.isEmpty {
                        loaded.append(ConversationTurn(
                            role: .assistant,
                            text: text,
                            groupId: groupId
                        ))
                    }
                default:
                    break
                }
            case "tool_execution_start":
                let toolName = event["toolName"] as? String ?? "tool"
                let argsDescription = (event["args"] as? [String: Any])?["description"] as? String
                loaded.append(ConversationTurn(
                    role: .tool,
                    text: "",
                    toolName: toolName,
                    toolCallDescription: argsDescription,
                    groupId: groupId
                ))
            case "tool_execution_end":
                // Attach result to the most recent tool turn — mirrors the
                // live handleEvent path, which assumes serial execution.
                let preview = Self.extractToolResultPreview(event["result"])
                if let idx = loaded.indices.reversed().first(where: { loaded[$0].role == .tool }) {
                    loaded[idx].text = preview
                }
            case "qa_findings":
                // Reconstruct the structured QA card from the persisted
                // event. Lives inside the current group so it renders
                // alongside the rest of the QA run's tool calls.
                let verdictRaw = event["verdict"] as? String ?? "info"
                let verdict = QaVerdict(rawValue: verdictRaw)
                let summary = event["summary"] as? String ?? ""
                let findingsRaw = event["findings"] as? [[String: Any]] ?? []
                let findings = findingsRaw.compactMap(QaFinding.init(json:))
                loaded.append(ConversationTurn(
                    role: .qaFindings,
                    text: summary,
                    groupId: groupId,
                    qaVerdict: verdict,
                    qaFindings: findings
                ))
            default:
                break
            }
        }
        self.turns = loaded
        self.groupKinds = rehydratedKinds
        self.lastGroupKind = rehydratedLastKind
    }

    private static func extractText(_ content: Any?) -> String {
        guard let arr = content as? [[String: Any]] else {
            return content as? String ?? ""
        }
        return arr.compactMap { item -> String? in
            if (item["type"] as? String) == "text" {
                return item["text"] as? String
            }
            return nil
        }.joined()
    }

    /// Pulls image parts out of a user-message content array
    /// (pi-ai shape: `[{ type: "image", data: <base64>, mimeType }, …]`).
    /// The Mac's local JSONL persists these verbatim, so history rehydration
    /// can show the same thumbnails the user saw live.
    private static func extractImages(_ content: Any?) -> [TurnImage] {
        guard let arr = content as? [[String: Any]] else { return [] }
        return arr.compactMap { item -> TurnImage? in
            guard (item["type"] as? String) == "image" else { return nil }
            return TurnImage(json: item)
        }
    }

    private static func extractToolResultPreview(_ result: Any?) -> String {
        guard let dict = result as? [String: Any] else { return "" }
        if let content = dict["content"] as? [[String: Any]],
           let first = content.first,
           let text = first["text"] as? String {
            return text.count > 800 ? String(text.prefix(800)) + "…" : text
        }
        return ""
    }

    public func bind(control: ControlClient) {
        self.control = control
    }

    /// True between message_start (assistant) and message_end. While set, the
    /// next text_delta will lazily create the assistant turn — that way
    /// assistant messages that contain only tool calls (no text) never produce
    /// an empty card.
    private var assistantTurnPending = false

    /// Allocated on agent_start, cleared on agent_end. Every turn appended
    /// while this is set carries it so the renderer can collapse the run
    /// into a single disclosure group ("6 tool calls, 1 message").
    private var currentGroupId: String?
    private var liveGroupCounter: Int = 0

    /// Force-clear streaming flags. Used when the underlying ControlClient
    /// disconnects mid-turn (sidecar crash, network blip). Caller is the
    /// AgentRegistryStore via its delegate path.
    public func cancelInFlight() {
        if isStreaming || assistantTurnPending {
            isStreaming = false
            assistantTurnPending = false
            for i in turns.indices { turns[i].streaming = false }
            turns.append(ConversationTurn(
                role: .assistant,
                text: "⚠️ Connection to the agent dropped mid-response. The session was reopened; please try again.",
                groupId: currentGroupId
            ))
            currentGroupId = nil
        }
    }

    public func handleEvent(_ event: AgentEventEnvelope) {
        guard event.workspaceId == workspaceId.uuidString else { return }
        switch event.type {
        case "agent_start":
            isStreaming = true
            liveGroupCounter += 1
            // Distinct prefix from history-replay ids ("g…") so live runs
            // can never collide with rehydrated ones in the same session.
            let gid = "live-\(liveGroupCounter)"
            currentGroupId = gid
            let kind: GroupKind = (event.payload["kind"] as? String) == "qa" ? .qa : .build
            groupKinds[gid] = kind
            lastGroupKind = kind
        case "agent_end":
            isStreaming = false
            assistantTurnPending = false
            currentGroupId = nil
            for i in turns.indices { turns[i].streaming = false }
        case "message_start":
            if let msg = event.payload["message"] as? [String: Any],
               (msg["role"] as? String) == "assistant" {
                assistantTurnPending = true
            }
        case "message_update":
            if let evt = event.payload["assistantMessageEvent"] as? [String: Any],
               evt["type"] as? String == "text_delta",
               let delta = evt["delta"] as? String {
                if assistantTurnPending {
                    turns.append(ConversationTurn(
                        role: .assistant,
                        text: "",
                        groupId: currentGroupId,
                        streaming: true
                    ))
                    assistantTurnPending = false
                }
                if let lastIdx = turns.indices.last,
                   turns[lastIdx].role == .assistant {
                    turns[lastIdx].text += delta
                }
            }
        case "message_end":
            assistantTurnPending = false
            if let lastIdx = turns.indices.last {
                turns[lastIdx].streaming = false
            }
            // pi-agent-core captures provider errors (rate limits, auth
            // failures, etc.) into a message_end with empty content and
            // stopReason="error". Without surfacing them, the user sees
            // no response and a stuck spinner. Render the errorMessage
            // as a ⚠️ assistant turn so the failure is visible.
            if let msg = event.payload["message"] as? [String: Any],
               (msg["stopReason"] as? String) == "error" {
                let errText = (msg["errorMessage"] as? String) ?? "agent error"
                lastError = errText
                turns.append(ConversationTurn(
                    role: .assistant,
                    text: "⚠️ " + errText,
                    groupId: currentGroupId,
                    streaming: false
                ))
            }
        case "agent_error":
            let msg = (event.payload["message"] as? String) ?? "agent error"
            lastError = msg
            assistantTurnPending = false
            // Surface the error as a turn so it survives in the transcript.
            turns.append(ConversationTurn(
                role: .assistant,
                text: "⚠️ " + msg,
                groupId: currentGroupId,
                streaming: false
            ))
        case "tool_execution_start":
            let name = event.payload["toolName"] as? String ?? "tool"
            let args = event.payload["args"] as? [String: Any]
            let callDesc = args?["description"] as? String
            let argText: String
            if let args { argText = "\(args)" } else { argText = "" }
            let preview = argText.count > 200 ? String(argText.prefix(200)) + "…" : argText
            turns.append(ConversationTurn(
                role: .tool,
                text: preview,
                toolName: name,
                toolCallDescription: callDesc,
                groupId: currentGroupId,
                streaming: true
            ))
        case "tool_execution_end":
            if let lastIdx = turns.indices.last, turns[lastIdx].role == .tool {
                turns[lastIdx].streaming = false
                let result = event.payload["result"]
                if let dict = result as? [String: Any],
                   let content = dict["content"] as? [[String: Any]],
                   let first = content.first,
                   let text = first["text"] as? String {
                    let preview = text.count > 800 ? String(text.prefix(800)) + "…" : text
                    turns[lastIdx].text = preview
                }
            }
        case "qa_findings":
            // Synthetic event the sidecar emits when the QA agent
            // invokes the post_qa_findings tool. Renders as a
            // structured card (verdict badge + summary + findings)
            // inside the current QA group.
            let verdictRaw = event.payload["verdict"] as? String ?? "info"
            let verdict = QaVerdict(rawValue: verdictRaw)
            let summary = event.payload["summary"] as? String ?? ""
            let findingsRaw = event.payload["findings"] as? [[String: Any]] ?? []
            let findings = findingsRaw.compactMap(QaFinding.init(json:))
            turns.append(ConversationTurn(
                role: .qaFindings,
                text: summary,
                groupId: currentGroupId,
                qaVerdict: verdict,
                qaFindings: findings
            ))
        default:
            break
        }
    }

    public func sendPrompt(_ text: String, images: [TurnImage] = []) async {
        turns.append(ConversationTurn(role: .user, text: text, images: images))
        var params: [String: Any] = [
            "workspaceId": workspaceId.uuidString,
            "message": text,
        ]
        if !images.isEmpty {
            // Base64-encode on the way out. The sidecar decodes and re-emits
            // the same shape into the JSONL log via message_end, so the
            // round-trip preserves the bytes exactly.
            params["images"] = images.map { img -> [String: String] in
                [
                    "data": img.data.base64EncodedString(),
                    "mimeType": img.mimeType,
                ]
            }
        }
        do {
            _ = try await control?.call(method: "agent.prompt", params: params)
        } catch {
            lastError = String(describing: error)
        }
    }
}

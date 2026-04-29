import Foundation
import Observation
import MultiharnessClient

/// Per-workspace agent state on the iOS side. Mirrors macOS's AgentStore but
/// receives events over the network rather than holding local sidecar state.
@MainActor
@Observable
public final class RemoteAgentStore {
    public let workspaceId: String
    public var turns: [ConversationTurn] = []
    public var isStreaming: Bool = false
    public var lastError: String?
    private var assistantTurnPending = false

    public init(workspaceId: String) {
        self.workspaceId = workspaceId
    }

    public func handleEvent(_ event: AgentEventEnvelope) {
        guard event.workspaceId == workspaceId else { return }
        switch event.type {
        case "agent_start":
            isStreaming = true
        case "agent_end":
            isStreaming = false
            assistantTurnPending = false
            for i in turns.indices { turns[i].streaming = false }
        case "agent_error":
            let msg = (event.payload["message"] as? String) ?? "agent error"
            lastError = msg
            assistantTurnPending = false
            turns.append(ConversationTurn(role: .assistant, text: "⚠️ " + msg))
        case "message_start":
            if let msg = event.payload["message"] as? [String: Any],
               (msg["role"] as? String) == "assistant" {
                assistantTurnPending = true
            }
        case "message_update":
            if let evt = event.payload["assistantMessageEvent"] as? [String: Any],
               (evt["type"] as? String) == "text_delta",
               let delta = evt["delta"] as? String {
                if assistantTurnPending {
                    turns.append(ConversationTurn(role: .assistant, text: "", streaming: true))
                    assistantTurnPending = false
                }
                if let last = turns.indices.last, turns[last].role == .assistant {
                    turns[last].text += delta
                }
            }
        case "message_end":
            assistantTurnPending = false
            if let last = turns.indices.last { turns[last].streaming = false }
        case "tool_execution_start":
            let name = event.payload["toolName"] as? String ?? "tool"
            turns.append(ConversationTurn(
                role: .tool,
                text: "",
                toolName: name,
                streaming: true
            ))
        case "tool_execution_end":
            if let last = turns.indices.last, turns[last].role == .tool {
                turns[last].streaming = false
                if let dict = event.payload["result"] as? [String: Any],
                   let content = dict["content"] as? [[String: Any]],
                   let first = content.first,
                   let text = first["text"] as? String {
                    let preview = text.count > 800 ? String(text.prefix(800)) + "…" : text
                    turns[last].text = preview
                }
            }
        default:
            break
        }
    }

    /// Reconstruct one turn from a remote.history payload entry.
    public static func turn(from json: [String: Any]) -> ConversationTurn? {
        guard let role = json["role"] as? String,
              let text = json["text"] as? String,
              let r = ConversationTurn.Role(rawValue: role)
        else { return nil }
        return ConversationTurn(
            role: r,
            text: text,
            toolName: json["toolName"] as? String
        )
    }
}

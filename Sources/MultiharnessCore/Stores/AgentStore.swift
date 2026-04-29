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

    private let env: AppEnvironment
    private weak var control: ControlClient?

    public init(env: AppEnvironment, workspaceId: UUID) {
        self.env = env
        self.workspaceId = workspaceId
        loadHistory()
    }

    /// Replay the persisted JSONL message log and reconstruct the visible turn
    /// list. Called once at construction so the user sees their prior
    /// conversation when they reopen a workspace (or after a sidecar crash).
    public func loadHistory() {
        let path = env.persistence.messagesPath(workspaceId: workspaceId)
        guard let data = try? Data(contentsOf: path),
              let text = String(data: data, encoding: .utf8) else { return }
        var loaded: [ConversationTurn] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = obj["event"] as? [String: Any],
                  let type = event["type"] as? String
            else { continue }
            switch type {
            case "message_end":
                guard let msg = event["message"] as? [String: Any],
                      let role = msg["role"] as? String
                else { continue }
                let text = Self.extractText(msg["content"])
                switch role {
                case "user":
                    if !text.isEmpty {
                        loaded.append(ConversationTurn(role: .user, text: text))
                    }
                case "assistant":
                    if !text.isEmpty {
                        loaded.append(ConversationTurn(role: .assistant, text: text))
                    }
                default:
                    break
                }
            case "tool_execution_end":
                let toolName = event["toolName"] as? String ?? "tool"
                let preview = Self.extractToolResultPreview(event["result"])
                loaded.append(ConversationTurn(
                    role: .tool,
                    text: preview,
                    toolName: toolName
                ))
            default:
                break
            }
        }
        self.turns = loaded
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

    public func handleEvent(_ event: AgentEventEnvelope) {
        guard event.workspaceId == workspaceId.uuidString else { return }
        switch event.type {
        case "agent_start":
            isStreaming = true
        case "agent_end":
            isStreaming = false
            assistantTurnPending = false
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
                    turns.append(ConversationTurn(role: .assistant, text: "", streaming: true))
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
        case "agent_error":
            let msg = (event.payload["message"] as? String) ?? "agent error"
            lastError = msg
            assistantTurnPending = false
            // Surface the error as a turn so it survives in the transcript.
            turns.append(ConversationTurn(
                role: .assistant,
                text: "⚠️ " + msg,
                streaming: false
            ))
        case "tool_execution_start":
            let name = event.payload["toolName"] as? String ?? "tool"
            let args = event.payload["args"]
            let argText: String
            if let args { argText = "\(args)" } else { argText = "" }
            let preview = argText.count > 200 ? String(argText.prefix(200)) + "…" : argText
            turns.append(ConversationTurn(role: .tool, text: preview, toolName: name, streaming: true))
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
        default:
            break
        }
    }

    public func sendPrompt(_ text: String) async {
        turns.append(ConversationTurn(role: .user, text: text))
        do {
            _ = try await control?.call(
                method: "agent.prompt",
                params: ["workspaceId": workspaceId.uuidString, "message": text]
            )
        } catch {
            lastError = String(describing: error)
        }
    }
}

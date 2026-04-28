import Foundation
import Observation

public struct ConversationTurn: Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var toolName: String?
    public var streaming: Bool = false
}

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
    }

    public func bind(control: ControlClient) {
        self.control = control
    }

    public func handleEvent(_ event: AgentEventEnvelope) {
        guard event.workspaceId == workspaceId.uuidString else { return }
        switch event.type {
        case "agent_start":
            isStreaming = true
        case "agent_end":
            isStreaming = false
            for i in turns.indices { turns[i].streaming = false }
        case "message_start":
            if let msg = event.payload["message"] as? [String: Any],
               let role = msg["role"] as? String,
               role == "assistant" {
                turns.append(ConversationTurn(role: .assistant, text: "", streaming: true))
            }
        case "message_update":
            if let evt = event.payload["assistantMessageEvent"] as? [String: Any],
               evt["type"] as? String == "text_delta",
               let delta = evt["delta"] as? String,
               let lastIdx = turns.indices.last,
               turns[lastIdx].role == .assistant {
                turns[lastIdx].text += delta
            }
        case "message_end":
            if let lastIdx = turns.indices.last {
                turns[lastIdx].streaming = false
            }
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

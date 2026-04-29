import Foundation

public struct ConversationTurn: Identifiable, Sendable {
    public enum Role: String, Sendable { case user, assistant, tool }
    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var toolName: String?
    public var streaming: Bool = false

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolName: String? = nil,
        streaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.streaming = streaming
    }
}

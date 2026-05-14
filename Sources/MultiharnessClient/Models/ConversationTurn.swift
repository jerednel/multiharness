import Foundation

/// One image attached to a user turn. `data` is the raw bytes (base64-decoded
/// at the wire boundary); `mimeType` is e.g. "image/png", "image/jpeg".
/// Sendable + Hashable so it works inside `ConversationTurn` and SwiftUI
/// `ForEach`. Identified by a stable UUID so reordering/animating works.
public struct TurnImage: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let data: Data
    public let mimeType: String

    public init(id: UUID = UUID(), data: Data, mimeType: String) {
        self.id = id
        self.data = data
        self.mimeType = mimeType
    }

    /// Decode a `{ data: <base64>, mimeType: <string> }` JSON dict the
    /// sidecar emits in `remote.history` and `message_end` events.
    public init?(json: [String: Any]) {
        guard let b64 = json["data"] as? String,
              let mime = json["mimeType"] as? String,
              let raw = Data(base64Encoded: b64)
        else { return nil }
        self.id = UUID()
        self.data = raw
        self.mimeType = mime
    }
}

/// One QA finding line — file/line are optional because the reviewer
/// may emit narrative-only notes that don't pin to a specific location.
public struct QaFinding: Sendable, Hashable, Identifiable {
    public enum Severity: String, Sendable { case info, warning, blocker }
    public let id: UUID
    public let severity: Severity
    public let file: String?
    public let line: Int?
    public let message: String

    public init(
        id: UUID = UUID(),
        severity: Severity,
        file: String? = nil,
        line: Int? = nil,
        message: String
    ) {
        self.id = id
        self.severity = severity
        self.file = file
        self.line = line
        self.message = message
    }

    /// Decode the `[{severity, file?, line?, message}]` shape emitted by
    /// the sidecar's `qa_findings` event (and the persisted JSONL).
    /// Returns nil when required fields are missing/malformed.
    public init?(json: [String: Any]) {
        guard let sevRaw = json["severity"] as? String,
              let severity = Severity(rawValue: sevRaw),
              let message = json["message"] as? String
        else { return nil }
        self.id = UUID()
        self.severity = severity
        self.file = json["file"] as? String
        // JSON numbers come back as Int or Double depending on
        // JSONSerialization's mood — accept both.
        if let i = json["line"] as? Int {
            self.line = i
        } else if let d = json["line"] as? Double {
            self.line = Int(d)
        } else {
            self.line = nil
        }
        self.message = message
    }
}

/// Top-level verdict from a QA review. String-backed so it survives
/// the `[String: Any]` payload extraction in `AgentStore`.
public enum QaVerdict: String, Sendable {
    case pass
    case minorIssues = "minor_issues"
    case blockingIssues = "blocking_issues"

    public var label: String {
        switch self {
        case .pass: return "Pass"
        case .minorIssues: return "Minor issues"
        case .blockingIssues: return "Blocking issues"
        }
    }
}

public struct ConversationTurn: Identifiable, Sendable {
    public enum Role: String, Sendable {
        case user, assistant, tool
        /// Synthetic, rendered from a `qa_findings` event the sidecar
        /// emits when the QA agent invokes `post_qa_findings`. Lives
        /// inside the same group as the rest of the QA run's turns so
        /// it disclose-collapses with them.
        case qaFindings = "qa_findings"
    }
    public var id: UUID = UUID()
    public var role: Role
    public var text: String
    public var toolName: String?
    /// Per-call label the model emitted via the tool's `description` arg
    /// (e.g. "Show working tree status"). Used as the primary step label
    /// when present; otherwise the UI falls back to a humanized toolName.
    public var toolCallDescription: String?
    /// All turns within a single agent_start..agent_end span share a groupId
    /// so the UI can collapse them under one disclosure header. User turns
    /// have no groupId. String (rather than UUID) because the sidecar's
    /// history replay synthesizes counter-style ids ("g1", "g2") which
    /// aren't valid UUIDs.
    public var groupId: String?
    public var streaming: Bool = false
    /// Inline image attachments. Only meaningful on user turns today, but
    /// kept on the type uniformly so future assistant-image support is a
    /// no-op for callers.
    public var images: [TurnImage] = []
    /// QA verdict + structured findings, only meaningful when
    /// `role == .qaFindings`. Defaulted to nil so the rest of the
    /// codebase doesn't need to care.
    public var qaVerdict: QaVerdict?
    public var qaFindings: [QaFinding] = []

    public init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        toolName: String? = nil,
        toolCallDescription: String? = nil,
        groupId: String? = nil,
        streaming: Bool = false,
        images: [TurnImage] = [],
        qaVerdict: QaVerdict? = nil,
        qaFindings: [QaFinding] = []
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.toolName = toolName
        self.toolCallDescription = toolCallDescription
        self.groupId = groupId
        self.streaming = streaming
        self.images = images
        self.qaVerdict = qaVerdict
        self.qaFindings = qaFindings
    }

    /// Display name for the tool: prefer the per-call description (set by
    /// the model), fall back to a humanized version of the snake_case tool
    /// name, fall back to "Tool".
    public var toolStepLabel: String {
        if let desc = toolCallDescription, !desc.isEmpty { return desc }
        if let name = toolName, !name.isEmpty { return Self.humanize(name) }
        return "Tool"
    }

    static func humanize(_ name: String) -> String {
        // Map a couple of names that don't humanize cleanly.
        switch name {
        case "bash": return "Bash"
        case "grep": return "Grep"
        case "glob": return "Glob"
        default: break
        }
        let parts = name.split(separator: "_").map(String.init)
        guard let first = parts.first else { return name }
        let head = first.prefix(1).uppercased() + first.dropFirst()
        let tail = parts.dropFirst().joined(separator: " ")
        return tail.isEmpty ? head : "\(head) \(tail)"
    }
}

/// Distinguishes the kind of agent run a group represents. Tagged onto
/// the group on `agent_start` and queried by the renderer to swap the
/// disclosure header between "build" and "🔍 QA review" appearances.
public enum GroupKind: String, Sendable {
    case build
    case qa
}

/// One row in the rendered conversation: either a standalone turn or a
/// collapsible response group whose children share a groupId. Both Mac and
/// iOS views consume this so they don't reimplement the grouping walk.
public enum ConversationRow: Identifiable, Sendable {
    case single(ConversationTurn)
    case group(id: String, children: [ConversationTurn])

    public var id: String {
        switch self {
        case .single(let t): return "single-\(t.id.uuidString)"
        case .group(let id, _): return "group-\(id)"
        }
    }
}

public func groupConversationTurns(_ turns: [ConversationTurn]) -> [ConversationRow] {
    var rows: [ConversationRow] = []
    var current: (id: String, children: [ConversationTurn])?
    func flush() {
        if let g = current { rows.append(.group(id: g.id, children: g.children)) }
        current = nil
    }
    for turn in turns {
        if let gid = turn.groupId {
            if current?.id == gid {
                current!.children.append(turn)
            } else {
                flush()
                current = (id: gid, children: [turn])
            }
        } else {
            flush()
            rows.append(.single(turn))
        }
    }
    flush()
    return rows
}

import Foundation

public enum SidebarMode: String, Codable, CaseIterable, Sendable, Equatable {
    case singleProject = "single_project"
    case allProjects = "all_projects"

    public var label: String {
        switch self {
        case .singleProject: return "Single project (grouped by status)"
        case .allProjects: return "All projects (collapsible)"
        }
    }
}

public enum LifecycleState: String, Codable, CaseIterable, Sendable, Equatable {
    case backlog
    case inProgress = "in_progress"
    case inReview = "in_review"
    case done
    case cancelled

    public var label: String {
        switch self {
        case .backlog: return "Backlog"
        case .inProgress: return "In progress"
        case .inReview: return "In review"
        case .done: return "Done"
        case .cancelled: return "Cancelled"
        }
    }

    /// Sidebar render order — matches the conductor.build screenshot.
    public static let sidebarOrder: [LifecycleState] = [
        .inProgress, .inReview, .done, .backlog, .cancelled,
    ]
}

public enum BuildMode: String, Codable, CaseIterable, Sendable, Equatable {
    case primary
    case shadowed

    public var label: String {
        switch self {
        case .primary: return "This worktree"
        case .shadowed: return "Local main"
        }
    }
}

public struct Project: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var repoPath: String
    public var defaultBaseBranch: String
    public var defaultProviderId: UUID?
    public var defaultModelId: String?
    public var createdAt: Date
    /// macOS security-scoped bookmark to the repo URL. Captured from
    /// `NSOpenPanel`'s implicit grant; resolved at app launch to suppress
    /// repeated TCC prompts for protected directories (Documents, Desktop, etc.).
    public var repoBookmark: Data?

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        repoPath: String,
        defaultBaseBranch: String = "main",
        defaultProviderId: UUID? = nil,
        defaultModelId: String? = nil,
        createdAt: Date = Date(),
        repoBookmark: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.repoPath = repoPath
        self.defaultBaseBranch = defaultBaseBranch
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.createdAt = createdAt
        self.repoBookmark = repoBookmark
    }
}

public struct Workspace: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var projectId: UUID
    public var name: String
    public var slug: String
    public var branchName: String
    public var baseBranch: String
    public var worktreePath: String
    public var lifecycleState: LifecycleState
    public var providerId: UUID
    public var modelId: String
    public var createdAt: Date
    public var archivedAt: Date?

    public init(
        id: UUID = UUID(),
        projectId: UUID,
        name: String,
        slug: String,
        branchName: String,
        baseBranch: String,
        worktreePath: String,
        lifecycleState: LifecycleState = .inProgress,
        providerId: UUID,
        modelId: String,
        createdAt: Date = Date(),
        archivedAt: Date? = nil
    ) {
        self.id = id
        self.projectId = projectId
        self.name = name
        self.slug = slug
        self.branchName = branchName
        self.baseBranch = baseBranch
        self.worktreePath = worktreePath
        self.lifecycleState = lifecycleState
        self.providerId = providerId
        self.modelId = modelId
        self.createdAt = createdAt
        self.archivedAt = archivedAt
    }
}

public enum ProviderKind: String, Codable, Sendable, Equatable {
    case piKnown = "pi-known"
    case openaiCompatible = "openai-compatible"
    case anthropic
    /// Anthropic OAuth (Claude Pro/Max). Tokens managed by the sidecar's
    /// OAuth store; no API key in Keychain.
    case anthropicOauth = "anthropic-oauth"
    /// OpenAI Codex OAuth (ChatGPT Plus/Pro).
    case openaiCodexOauth = "openai-codex-oauth"
}

public struct ProviderRecord: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var kind: ProviderKind
    /// For `pi-known` — pi-ai's KnownProvider id (e.g. "openrouter").
    /// For `openai-compatible` and `anthropic` — empty/unused (use baseUrl instead).
    public var piProvider: String?
    public var baseUrl: String?
    public var defaultModelId: String?
    /// Keychain account string. `nil` if no key required (e.g. local LM Studio).
    public var keychainAccount: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ProviderKind,
        piProvider: String? = nil,
        baseUrl: String? = nil,
        defaultModelId: String? = nil,
        keychainAccount: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.piProvider = piProvider
        self.baseUrl = baseUrl
        self.defaultModelId = defaultModelId
        self.keychainAccount = keychainAccount
        self.createdAt = createdAt
    }
}

public struct ProviderPreset: Sendable, Identifiable, Equatable {
    public let id: String
    public let displayName: String
    public let kind: ProviderKind
    public let piProvider: String?
    public let baseUrl: String?
    public let docsUrl: String?
    public let noKeyRequired: Bool

    public init(
        id: String,
        displayName: String,
        kind: ProviderKind,
        piProvider: String? = nil,
        baseUrl: String? = nil,
        docsUrl: String? = nil,
        noKeyRequired: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.piProvider = piProvider
        self.baseUrl = baseUrl
        self.docsUrl = docsUrl
        self.noKeyRequired = noKeyRequired
    }

    /// Mirrors PROVIDER_PRESETS in `sidecar/src/providers.ts`. Keep in sync.
    public static let builtins: [ProviderPreset] = [
        ProviderPreset(
            id: "lm-studio",
            displayName: "LM Studio (local)",
            kind: .openaiCompatible,
            baseUrl: "http://localhost:1234/v1",
            noKeyRequired: true
        ),
        ProviderPreset(
            id: "ollama",
            displayName: "Ollama (local)",
            kind: .openaiCompatible,
            baseUrl: "http://localhost:11434/v1",
            noKeyRequired: true
        ),
        ProviderPreset(
            id: "anthropic-oauth",
            displayName: "Sign in with Claude (Pro/Max)",
            kind: .anthropicOauth,
            piProvider: "anthropic",
            docsUrl: "https://claude.ai",
            noKeyRequired: true
        ),
        ProviderPreset(
            id: "openai-codex-oauth",
            displayName: "Sign in with ChatGPT (Plus/Pro)",
            kind: .openaiCodexOauth,
            piProvider: "openai-codex",
            docsUrl: "https://chat.openai.com",
            noKeyRequired: true
        ),
        ProviderPreset(
            id: "openrouter",
            displayName: "OpenRouter",
            kind: .piKnown,
            piProvider: "openrouter",
            docsUrl: "https://openrouter.ai/keys"
        ),
        ProviderPreset(
            id: "opencode",
            displayName: "OpenCode (Zen)",
            kind: .piKnown,
            piProvider: "opencode",
            docsUrl: "https://opencode.ai"
        ),
        ProviderPreset(
            id: "opencode-go",
            displayName: "OpenCode Go",
            kind: .piKnown,
            piProvider: "opencode-go",
            docsUrl: "https://opencode.ai"
        ),
        ProviderPreset(
            id: "openai",
            displayName: "OpenAI",
            kind: .piKnown,
            piProvider: "openai",
            docsUrl: "https://platform.openai.com/api-keys"
        ),
        ProviderPreset(
            id: "anthropic",
            displayName: "Anthropic",
            kind: .piKnown,
            piProvider: "anthropic",
            docsUrl: "https://console.anthropic.com/settings/keys"
        ),
    ]
}

/// Slugify a human name into a filesystem/branch-friendly identifier.
public func slugify(_ s: String) -> String {
    let lowered = s.lowercased()
    var out = ""
    var lastWasDash = false
    for c in lowered {
        if c.isLetter || c.isNumber {
            out.append(c)
            lastWasDash = false
        } else if !lastWasDash && !out.isEmpty {
            out.append("-")
            lastWasDash = true
        }
    }
    while out.hasSuffix("-") { out.removeLast() }
    return out.isEmpty ? "item" : out
}

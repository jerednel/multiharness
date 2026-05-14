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

public enum NameSource: String, Codable, Sendable, Equatable {
    /// Workspace is still using its auto-generated adjective-noun name and is
    /// eligible for an AI-assisted rename on first prompt.
    case random
    /// Workspace has a deliberate name (typed by the user, AI-renamed once,
    /// or manually renamed). The sidecar must not AI-rename it.
    case named
}

public struct Project: Codable, Identifiable, Sendable, Equatable, Hashable {
    public var id: UUID
    public var name: String
    public var slug: String
    public var repoPath: String
    public var defaultBaseBranch: String
    public var defaultProviderId: UUID?
    public var defaultModelId: String?
    public var defaultBuildMode: BuildMode?
    public var createdAt: Date
    /// macOS security-scoped bookmark to the repo URL. Captured from
    /// `NSOpenPanel`'s implicit grant; resolved at app launch to suppress
    /// repeated TCC prompts for protected directories (Documents, Desktop, etc.).
    public var repoBookmark: Data?
    public var contextInstructions: String
    /// Whether new workspaces in this project default to having QA review
    /// turned on. Workspaces can still opt out individually via
    /// `Workspace.qaEnabled`.
    public var defaultQaEnabled: Bool
    /// Pre-fill for the QA model picker on new workspaces (and the popover
    /// fallback when a workspace hasn't picked its own yet). Independent
    /// of `defaultQaEnabled` — a project may set these to "stage" a model
    /// without enabling QA broadly.
    public var defaultQaProviderId: UUID?
    public var defaultQaModelId: String?

    public init(
        id: UUID = UUID(),
        name: String,
        slug: String,
        repoPath: String,
        defaultBaseBranch: String = "main",
        defaultProviderId: UUID? = nil,
        defaultModelId: String? = nil,
        defaultBuildMode: BuildMode? = nil,
        createdAt: Date = Date(),
        repoBookmark: Data? = nil,
        contextInstructions: String = "",
        defaultQaEnabled: Bool = false,
        defaultQaProviderId: UUID? = nil,
        defaultQaModelId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.slug = slug
        self.repoPath = repoPath
        self.defaultBaseBranch = defaultBaseBranch
        self.defaultProviderId = defaultProviderId
        self.defaultModelId = defaultModelId
        self.defaultBuildMode = defaultBuildMode
        self.createdAt = createdAt
        self.repoBookmark = repoBookmark
        self.contextInstructions = contextInstructions
        self.defaultQaEnabled = defaultQaEnabled
        self.defaultQaProviderId = defaultQaProviderId
        self.defaultQaModelId = defaultQaModelId
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
    public var buildMode: BuildMode?
    public var createdAt: Date
    public var archivedAt: Date?
    public var nameSource: NameSource
    public var contextInstructions: String
    /// Last time the user opened this workspace in the UI. Used together
    /// with the latest persisted `agent_end` timestamp from messages.jsonl
    /// to decide whether to show an "unseen" dot on the workspace row.
    public var lastViewedAt: Date?
    /// Explicit QA opt-in/opt-out override. `nil` means "inherit project
    /// default"; `true`/`false` are explicit decisions. Stored as a
    /// nullable column so we can tell apart "user opted out" from
    /// "user never picked" — both look identical when projected to a
    /// non-nullable bool.
    public var qaEnabled: Bool?
    /// Workspace-level QA model picks. When non-nil, override the
    /// project-level defaults in the QA popover's pre-filled selection.
    /// Independent of `qaEnabled`: model picks persist through toggle
    /// changes so opting back in restores the previous selection.
    public var qaProviderId: UUID?
    public var qaModelId: String?

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
        buildMode: BuildMode? = nil,
        createdAt: Date = Date(),
        archivedAt: Date? = nil,
        nameSource: NameSource = .random,
        contextInstructions: String = "",
        lastViewedAt: Date? = Date(),
        qaEnabled: Bool? = nil,
        qaProviderId: UUID? = nil,
        qaModelId: String? = nil
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
        self.buildMode = buildMode
        self.createdAt = createdAt
        self.archivedAt = archivedAt
        self.nameSource = nameSource
        self.contextInstructions = contextInstructions
        self.lastViewedAt = lastViewedAt
        self.qaEnabled = qaEnabled
        self.qaProviderId = qaProviderId
        self.qaModelId = qaModelId
    }

    /// Resolves the effective build mode using the precedence chain:
    /// `workspace.buildMode → project.defaultBuildMode → .primary`.
    public func effectiveBuildMode(in project: Project) -> BuildMode {
        if let m = buildMode { return m }
        if let m = project.defaultBuildMode { return m }
        return .primary
    }

    /// Resolves the effective QA-enabled flag:
    /// `workspace.qaEnabled ?? project.defaultQaEnabled`. The composer's
    /// QA button reads this to decide its idle label.
    public func effectiveQaEnabled(in project: Project) -> Bool {
        qaEnabled ?? project.defaultQaEnabled
    }

    /// `(provider, model)` pair the QA popover should pre-select. Falls
    /// back to project defaults when the workspace hasn't recorded its
    /// own picks. Returns `(nil, nil)` when nothing is configured at
    /// either level.
    public func qaPopoverInitialSelection(
        in project: Project
    ) -> (providerId: UUID?, modelId: String?) {
        (
            qaProviderId ?? project.defaultQaProviderId,
            qaModelId ?? project.defaultQaModelId
        )
    }

    /// True iff the workspace carries an explicit `qaEnabled` value
    /// (either `true` or `false`) — drives whether the popover shows a
    /// "Use project default" affordance. We deliberately treat
    /// "explicit-and-matches-the-project" the same as
    /// "explicit-and-differs": the user made a deliberate decision, and
    /// the popover should let them reset it back to inheriting.
    public func qaEnabledIsOverridden(in project: Project) -> Bool {
        _ = project // suppress unused parameter warning while keeping the
                    // signature symmetric with the other QA helpers.
        return qaEnabled != nil
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

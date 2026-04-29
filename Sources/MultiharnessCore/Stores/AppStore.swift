import Foundation
import Observation
#if canImport(AppKit)
import AppKit
#endif

/// Owns app-level state: providers, projects, current selection.
@MainActor
@Observable
public final class AppStore {
    public var projects: [Project] = []
    public var providers: [ProviderRecord] = []
    public var selectedProjectId: UUID?
    public var sidebarMode: SidebarMode = .singleProject {
        didSet {
            guard oldValue != sidebarMode else { return }
            UserDefaults.standard.set(sidebarMode.rawValue, forKey: Self.sidebarModeDefaultsKey)
        }
    }
    public static let sidebarModeDefaultsKey = "MultiharnessSidebarMode"
    public var sidecarStatus: SidecarManager.Status = .stopped
    public var lastError: String?
    /// Increments every time the sidecar (re)binds. Views observe this to
    /// re-run their per-workspace `agent.create` after a sidecar restart.
    public var sidecarBindingVersion: Int = 0
    /// Number of in-flight relay requests from remote clients (iOS). When
    /// non-zero the Mac UI surfaces a small "iPhone activity" indicator so
    /// the user knows to glance over in case a TCC dialog needs approval.
    public var remoteActivityCount: Int = 0
    /// True while an Anthropic OAuth login is in flight.
    public var anthropicLoginInProgress: Bool = false
    public var anthropicLoginError: String?
    /// True while a ChatGPT (OpenAI Codex) OAuth login is in flight.
    public var openaiLoginInProgress: Bool = false
    public var openaiLoginError: String?

    private let env: AppEnvironment

    /// Convenience: pull every workspace across every project from SQLite.
    /// Used at boot / sidecar-rebind to bootstrap sessions remotely.
    public func persistenceWorkspaces() throws -> [Workspace] {
        try env.persistence.listWorkspaces(projectId: nil)
    }

    /// Tell the sidecar about every non-archived workspace so any client
    /// (Mac UI, iOS companion, future tooling) can call agent.prompt without
    /// first opening the workspace in the Mac UI. Idempotent — sessions that
    /// already exist surface "already exists" errors which we ignore.
    public func bootstrapAllSessions(workspaces: [Workspace]) async {
        for ws in workspaces where ws.archivedAt == nil {
            do {
                try await createAgentSession(for: ws)
            } catch AgentSessionError.controlClientUnavailable,
                    AgentSessionError.providerNotFound,
                    AgentSessionError.projectNotFound {
                continue  // bootstrap skips silently like before
            } catch {
                FileHandle.standardError.write(
                    "[bootstrap] agent.create for \(ws.name) failed: \(error)\n".data(using: .utf8) ?? Data()
                )
            }
        }
    }

    /// Create an agent session in the sidecar for the given workspace.
    /// Swallows "already exists" (idempotent). Throws `AgentSessionError` for
    /// missing pre-conditions and re-throws other `ControlError`s so callers
    /// can surface them to the user.
    @MainActor
    public func createAgentSession(for workspace: Workspace) async throws {
        guard let client = env.control else {
            throw AgentSessionError.controlClientUnavailable
        }
        guard let provider = providers.first(where: { $0.id == workspace.providerId }) else {
            throw AgentSessionError.providerNotFound
        }
        guard let project = projects.first(where: { $0.id == workspace.projectId }) else {
            throw AgentSessionError.projectNotFound
        }
        let cfg = providerConfig(provider: provider, modelId: workspace.modelId)
        let mode = workspace.effectiveBuildMode(in: project)
        let params: [String: Any] = [
            "workspaceId": workspace.id.uuidString,
            "worktreePath": workspace.worktreePath,
            "buildMode": mode.rawValue,
            "providerConfig": cfg,
        ]
        do {
            _ = try await client.call(method: "agent.create", params: params)
        } catch let e as ControlError {
            if case .remote(_, let msg) = e, msg.contains("already exists") {
                return  // benign — both callers treat this as success
            }
            throw e
        }
    }

    @MainActor
    public func setProjectDefaultBuildMode(projectId: UUID, mode: BuildMode) throws {
        guard let idx = projects.firstIndex(where: { $0.id == projectId }) else { return }
        var updated = projects[idx]
        updated.defaultBuildMode = mode
        try env.persistence.upsertProject(updated)
        projects[idx] = updated
    }

    public init(env: AppEnvironment) {
        self.env = env
        if let raw = UserDefaults.standard.string(forKey: Self.sidebarModeDefaultsKey),
           let mode = SidebarMode(rawValue: raw) {
            self.sidebarMode = mode
        }
        // Sync current status — sidecar.start() may have already fired before
        // this store was constructed, in which case the callback below would
        // never see the .running transition.
        self.sidecarStatus = env.sidecar.status
        env.sidecar.onStatusChange = { [weak self] s in
            Task { @MainActor in self?.sidecarStatus = s }
        }
    }

    public var selectedProject: Project? {
        guard let id = selectedProjectId else { return nil }
        return projects.first(where: { $0.id == id })
    }

    public func load() {
        do {
            self.projects = try env.persistence.listProjects()
            self.providers = try env.persistence.listProviders()
            // Reactivate persisted security-scoped bookmarks so subprocesses
            // (git, file reads) stop re-prompting for Documents/Desktop access.
            for proj in projects {
                if let bm = proj.repoBookmark {
                    _ = BookmarkScope.shared.resolve(id: proj.id, bookmark: bm)
                }
            }
            if selectedProjectId == nil {
                selectedProjectId = projects.first?.id
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Add a project from a URL the user just picked via NSOpenPanel — this is
    /// the moment to capture a security-scoped bookmark while the implicit
    /// grant is still active.
    public func addProject(name: String, repoURL: URL, defaultBaseBranch: String) {
        var bookmark: Data?
        do {
            bookmark = try BookmarkScope.makeBookmark(for: repoURL)
        } catch {
            // If bookmarking fails (e.g. URL is no longer accessible), fall
            // through and persist with no bookmark — we'll re-prompt later.
            FileHandle.standardError.write(
                "[app] bookmark for \(repoURL.path) failed: \(error)\n".data(using: .utf8) ?? Data()
            )
        }
        let p = Project(
            name: name,
            slug: slugify(name),
            repoPath: repoURL.path,
            defaultBaseBranch: defaultBaseBranch.isEmpty ? "main" : defaultBaseBranch,
            repoBookmark: bookmark
        )
        do {
            try env.persistence.upsertProject(p)
            projects.append(p)
            if let bm = bookmark {
                _ = BookmarkScope.shared.resolve(id: p.id, bookmark: bm)
            }
            if selectedProjectId == nil { selectedProjectId = p.id }
        } catch {
            lastError = String(describing: error)
        }
    }

    public func removeProject(_ project: Project) {
        do {
            BookmarkScope.shared.release(id: project.id)
            try env.persistence.deleteProject(id: project.id)
            projects.removeAll { $0.id == project.id }
            if selectedProjectId == project.id {
                selectedProjectId = projects.first?.id
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    public func addProvider(
        name: String,
        kind: ProviderKind,
        piProvider: String?,
        baseUrl: String?,
        defaultModelId: String?,
        apiKey: String?
    ) {
        let keychainAccount: String?
        if let k = apiKey, !k.isEmpty {
            keychainAccount = "\(name)-\(UUID().uuidString.prefix(8))"
        } else {
            keychainAccount = nil
        }
        let rec = ProviderRecord(
            name: name,
            kind: kind,
            piProvider: piProvider,
            baseUrl: baseUrl,
            defaultModelId: defaultModelId,
            keychainAccount: keychainAccount
        )
        do {
            if let acct = keychainAccount, let key = apiKey, !key.isEmpty {
                try env.keychain.setKey(key, account: acct)
            }
            try env.persistence.upsertProvider(rec)
            providers.append(rec)
        } catch {
            lastError = String(describing: error)
        }
    }

    public func setProviderDefaultModel(_ provider: ProviderRecord, modelId: String) {
        guard let idx = providers.firstIndex(where: { $0.id == provider.id }) else { return }
        var updated = providers[idx]
        updated.defaultModelId = modelId.isEmpty ? nil : modelId
        do {
            try env.persistence.upsertProvider(updated)
            providers[idx] = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func removeProvider(_ provider: ProviderRecord) {
        do {
            if let acct = provider.keychainAccount {
                try? env.keychain.deleteKey(account: acct)
            }
            try env.persistence.deleteProvider(id: provider.id)
            providers.removeAll { $0.id == provider.id }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Return the in-memory api key for a provider (resolves keychain) or nil if no account stored.
    public func apiKey(for provider: ProviderRecord) -> String? {
        guard let acct = provider.keychainAccount else { return nil }
        return try? env.keychain.getKey(account: acct)
    }

    /// Discovered model from the sidecar's `models.list` RPC.
    public struct DiscoveredModel: Identifiable, Hashable, Sendable {
        public let id: String
        public let name: String?
        public let contextWindow: Int?
        public let source: String
    }

    /// Fetch the available models for a provider via the sidecar's `models.list`.
    public func listModels(for provider: ProviderRecord) async throws -> [DiscoveredModel] {
        guard let client = env.control else {
            throw NSError(domain: "AppStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "control client not connected"])
        }
        // Build a wire config; modelId isn't used by listModels but is required by the type.
        let cfg = providerConfig(provider: provider, modelId: provider.defaultModelId ?? "unspecified")
        let result = try await client.call(method: "models.list", params: ["providerConfig": cfg]) as? [String: Any]
        let arr = result?["models"] as? [[String: Any]] ?? []
        return arr.compactMap { dict in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            return DiscoveredModel(
                id: id,
                name: dict["name"] as? String,
                contextWindow: (dict["contextWindow"] as? Int) ?? (dict["contextWindow"] as? Double).map(Int.init),
                source: (dict["source"] as? String) ?? "remote"
            )
        }
    }

    /// Build the wire-level provider config the sidecar expects.
    public func providerConfig(provider: ProviderRecord, modelId: String) -> [String: Any] {
        switch provider.kind {
        case .piKnown:
            var cfg: [String: Any] = [
                "kind": "pi-known",
                "provider": provider.piProvider ?? "",
                "modelId": modelId,
            ]
            if let key = apiKey(for: provider) { cfg["apiKey"] = key }
            return cfg
        case .openaiCompatible:
            var cfg: [String: Any] = [
                "kind": "openai-compatible",
                "modelId": modelId,
                "baseUrl": provider.baseUrl ?? "",
            ]
            if let key = apiKey(for: provider) { cfg["apiKey"] = key }
            return cfg
        case .anthropic:
            var cfg: [String: Any] = [
                "kind": "anthropic",
                "modelId": modelId,
                "apiKey": apiKey(for: provider) ?? "",
            ]
            if let url = provider.baseUrl { cfg["baseUrl"] = url }
            return cfg
        case .anthropicOauth:
            return [
                "kind": "anthropic-oauth",
                "modelId": modelId,
            ]
        case .openaiCodexOauth:
            return [
                "kind": "openai-codex-oauth",
                "modelId": modelId,
            ]
        }
    }

    // MARK: - Anthropic OAuth

    /// Kick off the Anthropic OAuth flow. The sidecar opens a local
    /// callback server, surfaces the auth URL via an `anthropic_auth_url`
    /// event, and resolves when login completes. On success we add a
    /// ProviderRecord with kind .anthropicOauth so the user can pick it
    /// when creating workspaces.
    public func signInWithAnthropic() async {
        guard let client = env.control else {
            anthropicLoginError = "control client not connected"
            return
        }
        anthropicLoginInProgress = true
        anthropicLoginError = nil
        defer { anthropicLoginInProgress = false }
        do {
            _ = try await client.call(method: "auth.anthropic.start", params: [:])
            // On success, add a provider record (idempotent — skip if one
            // already exists with kind anthropicOauth).
            if !providers.contains(where: { $0.kind == .anthropicOauth }) {
                addProvider(
                    name: "Claude (OAuth)",
                    kind: .anthropicOauth,
                    piProvider: "anthropic",
                    baseUrl: nil,
                    defaultModelId: nil,
                    apiKey: nil
                )
            }
        } catch {
            anthropicLoginError = String(describing: error)
        }
    }

    /// Called by the registry when an `anthropic_auth_url` event arrives.
    public func openAnthropicAuthURL(_ url: String) {
        openExternalURL(url)
    }

    /// Same flow as signInWithAnthropic but for ChatGPT (OpenAI Codex).
    public func signInWithChatGPT() async {
        guard let client = env.control else {
            openaiLoginError = "control client not connected"
            return
        }
        openaiLoginInProgress = true
        openaiLoginError = nil
        defer { openaiLoginInProgress = false }
        do {
            _ = try await client.call(method: "auth.openai.start", params: [:])
            if !providers.contains(where: { $0.kind == .openaiCodexOauth }) {
                addProvider(
                    name: "ChatGPT (OAuth)",
                    kind: .openaiCodexOauth,
                    piProvider: "openai-codex",
                    baseUrl: nil,
                    defaultModelId: nil,
                    apiKey: nil
                )
            }
        } catch {
            openaiLoginError = String(describing: error)
        }
    }

    public func openOpenAIAuthURL(_ url: String) {
        openExternalURL(url)
    }

    private func openExternalURL(_ url: String) {
        if let u = URL(string: url) {
            #if canImport(AppKit)
            NSWorkspace.shared.open(u)
            #endif
        }
    }
}

// MARK: - AgentSessionError

public enum AgentSessionError: Error, CustomStringConvertible {
    case controlClientUnavailable
    case providerNotFound
    case projectNotFound

    public var description: String {
        switch self {
        case .controlClientUnavailable: return "control client not connected"
        case .providerNotFound: return "provider not found"
        case .projectNotFound: return "project not found"
        }
    }
}

import Foundation
import Observation

/// Owns app-level state: providers, projects, current selection.
@MainActor
@Observable
public final class AppStore {
    public var projects: [Project] = []
    public var providers: [ProviderRecord] = []
    public var selectedProjectId: UUID?
    public var sidecarStatus: SidecarManager.Status = .stopped
    public var lastError: String?

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
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
        }
    }
}

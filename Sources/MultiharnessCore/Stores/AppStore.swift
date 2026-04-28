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
            if selectedProjectId == nil {
                selectedProjectId = projects.first?.id
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    public func addProject(name: String, repoPath: String, defaultBaseBranch: String) {
        let p = Project(
            name: name,
            slug: slugify(name),
            repoPath: repoPath,
            defaultBaseBranch: defaultBaseBranch.isEmpty ? "main" : defaultBaseBranch
        )
        do {
            try env.persistence.upsertProject(p)
            projects.append(p)
            if selectedProjectId == nil { selectedProjectId = p.id }
        } catch {
            lastError = String(describing: error)
        }
    }

    public func removeProject(_ project: Project) {
        do {
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

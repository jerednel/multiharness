import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceStore {
    public var workspaces: [Workspace] = []
    public var selectedWorkspaceId: UUID?
    public var lastError: String?

    /// Cache of the latest `agent_end` timestamp observed in each workspace's
    /// messages.jsonl. Populated on `load(projectId:)` and updated by callers
    /// (e.g. AgentRegistryStore) on live `agent_end` events.
    public private(set) var lastAssistantAt: [UUID: Date] = [:]

    private let env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public func load(projectId: UUID?) {
        do {
            self.workspaces = try env.persistence.listWorkspaces(projectId: projectId)
            if let id = selectedWorkspaceId, !workspaces.contains(where: { $0.id == id }) {
                selectedWorkspaceId = nil
            }
            // Refresh lastAssistantAt for every loaded workspace. Reads JSONL
            // off-disk; cheap because each file is small (<1MB typical).
            var fresh: [UUID: Date] = [:]
            for w in workspaces {
                if let ts = try? env.persistence.lastAssistantAt(workspaceId: w.id) {
                    fresh[w.id] = ts
                }
            }
            self.lastAssistantAt = fresh
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Load every workspace across every project. Used by the all-projects
    /// sidebar mode.
    public func loadAll() {
        load(projectId: nil)
    }

    public func grouped() -> [(LifecycleState, [Workspace])] {
        grouped(projectId: nil)
    }

    /// Group `projectId`'s workspaces by lifecycle state in sidebar order.
    /// Pass `nil` to group across every loaded workspace.
    public func grouped(projectId: UUID?) -> [(LifecycleState, [Workspace])] {
        var buckets: [LifecycleState: [Workspace]] = [:]
        for w in workspaces where w.archivedAt == nil {
            if let pid = projectId, w.projectId != pid { continue }
            buckets[w.lifecycleState, default: []].append(w)
        }
        return LifecycleState.sidebarOrder.compactMap { state in
            guard let arr = buckets[state], !arr.isEmpty else { return nil }
            return (state, arr)
        }
    }

    /// Non-archived workspaces for `projectId`, sorted by createdAt
    /// descending. Used by the all-projects flat view.
    public func workspaces(for projectId: UUID) -> [Workspace] {
        workspaces
            .filter { $0.projectId == projectId && $0.archivedAt == nil }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func selected() -> Workspace? {
        guard let id = selectedWorkspaceId else { return nil }
        return workspaces.first(where: { $0.id == id })
    }

    /// Mark a workspace as just-viewed: persist now() to last_viewed_at and
    /// reflect it in the in-memory copy so unseen(_:) flips to false
    /// immediately. Safe to call repeatedly.
    public func markViewed(_ id: UUID) {
        do {
            try env.persistence.markWorkspaceViewed(id: id)
            if let idx = workspaces.firstIndex(where: { $0.id == id }) {
                workspaces[idx].lastViewedAt = Date()
            }
        } catch {
            lastError = String(describing: error)
        }
    }

    /// True iff this workspace's most recent `agent_end` happened after the
    /// user last viewed it. Returns false when there's been no agent activity
    /// at all.
    public func unseen(_ ws: Workspace) -> Bool {
        guard let lastEnd = lastAssistantAt[ws.id] else { return false }
        guard let viewed = ws.lastViewedAt else { return true }
        return lastEnd > viewed
    }

    /// Record a fresh `agent_end` for a workspace at the current wall-clock.
    /// Called by AgentRegistryStore when it sees an `agent_end` event from
    /// the sidecar.
    public func recordAssistantEnd(workspaceId: UUID) {
        lastAssistantAt[workspaceId] = Date()
    }

    @discardableResult
    public func create(
        project: Project,
        name: String,
        baseBranch: String,
        provider: ProviderRecord,
        modelId: String,
        gitUserName: String,
        buildMode: BuildMode? = nil,
        nameSource: NameSource = .named
    ) throws -> Workspace {
        let slug = slugify(name)
        let branch = "\(slugify(gitUserName))/\(slug)"
        let path = env.worktree.worktreePath(projectSlug: project.slug, workspaceSlug: slug)
        try env.worktree.createWorktree(
            repoPath: project.repoPath,
            baseBranch: baseBranch,
            branchName: branch,
            worktreePath: path
        )
        let ws = Workspace(
            projectId: project.id,
            name: name,
            slug: slug,
            branchName: branch,
            baseBranch: baseBranch,
            worktreePath: path.path,
            providerId: provider.id,
            modelId: modelId,
            buildMode: buildMode,
            nameSource: nameSource
        )
        try env.persistence.upsertWorkspace(ws)
        workspaces.insert(ws, at: 0)
        selectedWorkspaceId = ws.id
        return ws
    }

    /// Update only the display name of a workspace. The slug, branch name,
    /// and worktree path stay frozen at their original values — see
    /// docs/superpowers/specs/2026-04-29-ai-workspace-names-design.md.
    /// Always flips `nameSource` to `.named` so future AI rename attempts
    /// are skipped.
    public func rename(_ ws: Workspace, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let idx = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        var updated = workspaces[idx]
        updated.name = trimmed
        updated.nameSource = .named
        do {
            try env.persistence.upsertWorkspace(updated)
            workspaces[idx] = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Request a rename through the sidecar. The call goes out as
    /// `workspace.rename` and round-trips back to this Mac process via the
    /// relay handler, which calls `rename(_:to:)` to update the in-memory
    /// store; the sidecar additionally broadcasts a `workspace_updated`
    /// event so connected iOS clients pick up the new name.
    public func requestRename(_ ws: Workspace, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let client = env.control else {
            throw RenameError.controlClientUnavailable
        }
        _ = try await client.call(
            method: "workspace.rename",
            params: [
                "workspaceId": ws.id.uuidString,
                "name": trimmed,
            ]
        )
    }

    public enum RenameError: Error, LocalizedError {
        case controlClientUnavailable
        public var errorDescription: String? {
            switch self {
            case .controlClientUnavailable:
                return "Sidecar isn't running yet — try again in a moment."
            }
        }
    }

    public enum QuickCreateError: Error, LocalizedError {
        case noProviderAvailable
        case noModelAvailable
        public var errorDescription: String? {
            switch self {
            case .noProviderAvailable:
                return "No provider configured. Add one in Settings."
            case .noModelAvailable:
                return "No model could be determined. Set one in Settings → Defaults or on the project."
            }
        }
    }

    /// Output of the inheritance chain used by quick-create. The struct can
    /// describe a fully-resolved tuple, a partial one ("we got a provider
    /// but no model"), or nothing useful at all. `missing` is the list of
    /// fields the chain couldn't fill — empty means quick-create may proceed.
    public struct QuickCreateResolution: Sendable {
        public let providerId: UUID?
        public let modelId: String?
        public let baseBranch: String
        public let buildMode: BuildMode?
        public let name: String

        public var missing: [String] {
            var m: [String] = []
            if providerId == nil { m.append("provider") }
            if modelId == nil || modelId?.isEmpty == true { m.append("model") }
            return m
        }
    }

    /// Pure resolver — no side effects, no creation. Both `quickCreate` and
    /// the iOS relay handler call this and act on the result.
    public func resolveQuickCreateInputs(
        project: Project,
        providers: [ProviderRecord],
        globalDefault: (providerId: UUID, modelId: String)?
    ) -> QuickCreateResolution {
        let inherit = selected().flatMap { $0.projectId == project.id ? $0 : nil }

        // Provider chain: inherit → project default → global default →
        // first available. Each step only counts when the candidate id
        // still maps to a real entry in `providers`.
        let provider: ProviderRecord? = {
            let candidates: [UUID?] = [
                inherit?.providerId,
                project.defaultProviderId,
                globalDefault?.providerId,
            ]
            for c in candidates {
                if let pid = c, let p = providers.first(where: { $0.id == pid }) {
                    return p
                }
            }
            return providers.first
        }()

        // Model chain: inherit → project default → provider default →
        // global default. Only the last two depend on the resolved
        // provider; the first two are project-scoped.
        let modelId: String? = {
            if let m = inherit?.modelId, !m.isEmpty { return m }
            if let m = project.defaultModelId, !m.isEmpty { return m }
            if let p = provider, let m = p.defaultModelId, !m.isEmpty { return m }
            if let m = globalDefault?.modelId, !m.isEmpty { return m }
            return nil
        }()

        let baseBranch = inherit?.baseBranch ?? project.defaultBaseBranch
        let existingSlugs = Set(
            workspaces.filter { $0.projectId == project.id }.map { $0.slug }
        )
        return QuickCreateResolution(
            providerId: provider?.id,
            modelId: modelId,
            baseBranch: baseBranch,
            buildMode: project.defaultBuildMode,
            name: RandomName.generateUnique(avoiding: existingSlugs)
        )
    }

    /// One-click workspace creation. Inherits provider/model/baseBranch
    /// from the currently selected workspace (when it belongs to `project`)
    /// or falls back through project default → global default → provider
    /// default → first available. Generates a unique adjective-noun name.
    @discardableResult
    public func quickCreate(
        project: Project,
        providers: [ProviderRecord],
        gitUserName: String,
        globalDefault: (providerId: UUID, modelId: String)? = nil
    ) throws -> Workspace {
        let resolution = resolveQuickCreateInputs(
            project: project, providers: providers, globalDefault: globalDefault
        )
        guard let pid = resolution.providerId,
              let provider = providers.first(where: { $0.id == pid })
        else { throw QuickCreateError.noProviderAvailable }
        guard let modelId = resolution.modelId, !modelId.isEmpty
        else { throw QuickCreateError.noModelAvailable }
        return try create(
            project: project,
            name: resolution.name,
            baseBranch: resolution.baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: gitUserName,
            buildMode: resolution.buildMode,
            nameSource: .random
        )
    }

    public func setLifecycle(_ ws: Workspace, _ state: LifecycleState) {
        guard let idx = workspaces.firstIndex(where: { $0.id == ws.id }) else { return }
        var updated = workspaces[idx]
        updated.lifecycleState = state
        do {
            try env.persistence.upsertWorkspace(updated)
            workspaces[idx] = updated
        } catch {
            lastError = String(describing: error)
        }
    }

    public func archive(_ ws: Workspace, removeWorktree: Bool) {
        var updated = ws
        updated.archivedAt = Date()
        do {
            if removeWorktree {
                try? env.worktree.removeWorktree(
                    repoPath: workspaces.first(where: { $0.id == ws.id })?.worktreePath ?? "",
                    worktreePath: ws.worktreePath,
                    force: true
                )
            }
            try env.persistence.upsertWorkspace(updated)
            workspaces.removeAll { $0.id == ws.id }
            if selectedWorkspaceId == ws.id { selectedWorkspaceId = nil }
        } catch {
            lastError = String(describing: error)
        }
    }
}

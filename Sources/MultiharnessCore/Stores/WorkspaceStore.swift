import Foundation
import Observation

@MainActor
@Observable
public final class WorkspaceStore {
    public var workspaces: [Workspace] = []
    public var selectedWorkspaceId: UUID?
    public var lastError: String?

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

    @discardableResult
    public func create(
        project: Project,
        name: String,
        baseBranch: String,
        provider: ProviderRecord,
        modelId: String,
        gitUserName: String
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
            modelId: modelId
        )
        try env.persistence.upsertWorkspace(ws)
        workspaces.insert(ws, at: 0)
        selectedWorkspaceId = ws.id
        return ws
    }

    public enum QuickCreateError: Error, LocalizedError {
        case noProviderAvailable
        public var errorDescription: String? {
            switch self {
            case .noProviderAvailable:
                return "No provider configured. Add one in Settings."
            }
        }
    }

    /// One-click workspace creation. Inherits provider/model/baseBranch
    /// from the currently selected workspace (when it belongs to `project`)
    /// or falls back to project defaults. Generates a unique
    /// adjective-noun name.
    @discardableResult
    public func quickCreate(
        project: Project,
        providers: [ProviderRecord],
        gitUserName: String
    ) throws -> Workspace {
        let inherit = selected().flatMap { $0.projectId == project.id ? $0 : nil }
        let providerId = inherit?.providerId ?? project.defaultProviderId
        let modelId = inherit?.modelId ?? project.defaultModelId
        let baseBranch = inherit?.baseBranch ?? project.defaultBaseBranch

        let provider: ProviderRecord
        if let pid = providerId, let p = providers.first(where: { $0.id == pid }) {
            provider = p
        } else if let first = providers.first {
            provider = first
        } else {
            throw QuickCreateError.noProviderAvailable
        }

        let resolvedModelId = modelId
            ?? provider.defaultModelId
            ?? ""
        guard !resolvedModelId.isEmpty else {
            throw QuickCreateError.noProviderAvailable
        }

        let existingSlugs = Set(
            workspaces
                .filter { $0.projectId == project.id }
                .map { $0.slug }
        )
        let name = RandomName.generateUnique(avoiding: existingSlugs)
        return try create(
            project: project,
            name: name,
            baseBranch: baseBranch,
            provider: provider,
            modelId: resolvedModelId,
            gitUserName: gitUserName
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

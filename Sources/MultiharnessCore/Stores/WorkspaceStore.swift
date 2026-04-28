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

    public func grouped() -> [(LifecycleState, [Workspace])] {
        var buckets: [LifecycleState: [Workspace]] = [:]
        for w in workspaces where w.archivedAt == nil {
            buckets[w.lifecycleState, default: []].append(w)
        }
        return LifecycleState.sidebarOrder.compactMap { state in
            guard let arr = buckets[state], !arr.isEmpty else { return nil }
            return (state, arr)
        }
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

import Foundation
import MultiharnessCore

/// Wires Mac-side execution into the relay handler. Each registered closure
/// is the implementation for one method that iOS can call via the sidecar.
@MainActor
enum RemoteHandlers {

    static func register(
        on relay: RelayHandler,
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async {
        await relay.register(method: "workspace.create") { params in
            try await Self.workspaceCreate(
                params: params,
                env: env, appStore: appStore, workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "project.scan") { _ in
            try await Self.projectScan()
        }
        await relay.register(method: "project.create") { params in
            try await Self.projectCreate(params: params, env: env, appStore: appStore)
        }
    }

    // MARK: - workspace.create

    @MainActor
    private static func workspaceCreate(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let projectIdStr = params["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            throw RemoteError.bad("name required")
        }
        guard let providerIdStr = params["providerId"] as? String,
              let providerId = UUID(uuidString: providerIdStr) else {
            throw RemoteError.bad("providerId required (UUID string)")
        }
        guard let modelId = (params["modelId"] as? String)?.trimmingCharacters(in: .whitespaces),
              !modelId.isEmpty else {
            throw RemoteError.bad("modelId required")
        }

        guard let project = appStore.projects.first(where: { $0.id == projectId }) else {
            throw RemoteError.bad("project not found")
        }
        guard let provider = appStore.providers.first(where: { $0.id == providerId }) else {
            throw RemoteError.bad("provider not found")
        }
        let baseBranch = (params["baseBranch"] as? String) ?? project.defaultBaseBranch
        let userName = NSUserName()

        let workspace = try workspaceStore.create(
            project: project,
            name: name,
            baseBranch: baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: userName
        )

        // Bootstrap an agent session so iOS can prompt immediately.
        await appStore.bootstrapAllSessions(workspaces: [workspace])

        return [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "branchName": workspace.branchName,
            "worktreePath": workspace.worktreePath,
            "lifecycleState": workspace.lifecycleState.rawValue,
            "modelId": workspace.modelId,
        ]
    }

    // MARK: - project.scan

    /// Scan a few common dev directories for git repositories so the iOS app
    /// can show a pick-list (it can't browse the Mac filesystem itself).
    /// Returns a best-effort, depth-limited list — we don't recurse into
    /// every nested git repo.
    @MainActor
    private static func projectScan() async throws -> Any? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent("dev"),
            home.appendingPathComponent("projects"),
            home.appendingPathComponent("code"),
            home.appendingPathComponent("Documents/code"),
            home.appendingPathComponent("Documents/dev"),
            home.appendingPathComponent("Documents/projects"),
            home.appendingPathComponent("conductor"),
            home.appendingPathComponent("git"),
            home.appendingPathComponent("workspace"),
            home.appendingPathComponent("Sites"),
        ]
        var repos: [[String: Any]] = []
        let fm = FileManager.default
        for root in candidates {
            guard fm.fileExists(atPath: root.path) else { continue }
            // Search at depth 1, 2, and 3 — enough to catch ~/dev/<repo>,
            // ~/dev/<org>/<repo>, ~/conductor/workspaces/<x>/<y>.
            await collectRepos(under: root, maxDepth: 3, into: &repos)
        }
        return ["repos": repos]
    }

    private static func collectRepos(
        under root: URL,
        maxDepth: Int,
        into out: inout [[String: Any]]
    ) async {
        let fm = FileManager.default
        var stack: [(URL, Int)] = [(root, 0)]
        while let (dir, depth) = stack.popLast() {
            let gitDir = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: gitDir.path) {
                out.append([
                    "path": dir.path,
                    "name": dir.lastPathComponent,
                ])
                continue   // don't recurse into a repo
            }
            if depth >= maxDepth { continue }
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for e in entries {
                let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { stack.append((e, depth + 1)) }
            }
        }
    }

    // MARK: - project.create

    @MainActor
    private static func projectCreate(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore
    ) async throws -> Any? {
        guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            throw RemoteError.bad("name required")
        }
        guard let repoPath = (params["repoPath"] as? String)?.trimmingCharacters(in: .whitespaces),
              !repoPath.isEmpty else {
            throw RemoteError.bad("repoPath required")
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repoPath, isDirectory: &isDir),
              isDir.boolValue else {
            throw RemoteError.bad("repoPath does not exist or is not a directory")
        }
        let gitDir = (repoPath as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            throw RemoteError.bad("repoPath is not a git repository (no .git found)")
        }
        let baseBranch = (params["defaultBaseBranch"] as? String) ?? "main"
        // No security-scoped bookmark — iOS-initiated adds happen without
        // an NSOpenPanel grant. Mac will hit a TCC prompt the first time a
        // tool reads the directory if it's under Documents/Desktop.
        appStore.addProject(name: name, repoURL: URL(fileURLWithPath: repoPath), defaultBaseBranch: baseBranch)
        guard let added = appStore.projects.first(where: { $0.repoPath == repoPath }) else {
            throw RemoteError.bad("project insert failed")
        }
        return [
            "id": added.id.uuidString,
            "name": added.name,
            "slug": added.slug,
            "repoPath": added.repoPath,
            "defaultBaseBranch": added.defaultBaseBranch,
        ]
    }
}

enum RemoteError: Error, CustomStringConvertible {
    case bad(String)
    var description: String {
        switch self {
        case .bad(let m): return m
        }
    }
}

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
        workspaceStore: WorkspaceStore,
        branchListService: BranchListService
    ) async {
        await relay.register(method: "workspace.create") { params in
            try await Self.workspaceCreate(
                params: params,
                env: env, appStore: appStore, workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "workspace.rename") { params in
            try await Self.workspaceRename(
                params: params, workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "project.scan") { _ in
            try await Self.projectScan()
        }
        await relay.register(method: "project.create") { params in
            try await Self.projectCreate(params: params, env: env, appStore: appStore)
        }
        await relay.register(method: "models.listForProvider") { params in
            try await Self.modelsListForProvider(params: params, env: env, appStore: appStore)
        }
        await relay.register(method: "fs.list") { params in
            try await Self.fsList(params: params)
        }
        await relay.register(method: "workspace.setContext") { params in
            try await Self.workspaceSetContext(
                params: params, env: env, appStore: appStore, workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "project.setContext") { params in
            try await Self.projectSetContext(
                params: params, env: env, appStore: appStore
            )
        }
        await relay.register(method: "workspace.markViewed") { params in
            try await Self.workspaceMarkViewed(
                params: params,
                workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "workspace.quickCreate") { params in
            try await Self.workspaceQuickCreate(
                params: params,
                env: env, appStore: appStore, workspaceStore: workspaceStore
            )
        }
        await relay.register(method: "project.listBranches") { params in
            guard let pidStr = params["projectId"] as? String,
                  let pid = UUID(uuidString: pidStr),
                  let project = appStore.projects.first(where: { $0.id == pid }) else {
                throw RemoteError.bad("projectId required (UUID of known project)")
            }
            return try await RemoteBranchHandler.handleListBranches(
                params: params,
                repoPath: project.repoPath,
                service: branchListService
            )
        }
        await relay.register(method: "project.update") { params in
            try await RemoteBranchHandler.handleProjectUpdate(
                params: params,
                appStore: appStore,
                branchListService: branchListService
            )
        }
    }

    // MARK: - workspace.setContext

    @MainActor
    private static func workspaceSetContext(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let idStr = params["workspaceId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("workspaceId required (UUID string)")
        }
        let text = (params["contextInstructions"] as? String) ?? ""
        try await appStore.setWorkspaceContext(
            workspaceStore: workspaceStore,
            workspaceId: id,
            text: text
        )
        return ["ok": true]
    }

    // MARK: - project.setContext

    @MainActor
    private static func projectSetContext(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore
    ) async throws -> Any? {
        guard let idStr = params["projectId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        let text = (params["contextInstructions"] as? String) ?? ""
        try await appStore.setProjectContext(projectId: id, text: text)
        return ["ok": true]
    }

    // MARK: - workspace.markViewed

    @MainActor
    private static func workspaceMarkViewed(
        params: [String: Any],
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let idStr = params["workspaceId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("workspaceId required (UUID string)")
        }
        workspaceStore.markViewed(id)
        return ["workspaceId": idStr]
    }

    // MARK: - models.listForProvider

    /// iOS asks the Mac to enumerate models for a registered provider.
    /// Mac builds the full providerConfig (resolving the API key from
    /// Keychain) and calls `models.list` on the sidecar locally — meaning
    /// the API key never leaves the Mac.
    @MainActor
    private static func modelsListForProvider(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore
    ) async throws -> Any? {
        guard let providerIdStr = params["providerId"] as? String,
              let providerId = UUID(uuidString: providerIdStr) else {
            throw RemoteError.bad("providerId required (UUID string)")
        }
        guard let provider = appStore.providers.first(where: { $0.id == providerId }) else {
            throw RemoteError.bad("provider not found")
        }
        let cfg = appStore.providerConfig(
            provider: provider,
            modelId: provider.defaultModelId ?? ""
        )
        guard let client = env.control else {
            throw RemoteError.bad("sidecar control client not bound")
        }
        let result = try await client.call(
            method: "models.list",
            params: ["providerConfig": cfg]
        ) as? [String: Any]
        let arr = (result?["models"] as? [[String: Any]]) ?? []
        let trimmed = arr.compactMap { dict -> [String: Any]? in
            guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
            var out: [String: Any] = ["id": id]
            if let name = dict["name"] as? String { out["name"] = name }
            return out
        }
        return ["models": trimmed]
    }

    // MARK: - workspace.rename

    /// Display-name-only rename. Slug, branch_name, and worktree_path stay
    /// frozen — see docs/superpowers/specs/2026-04-29-ai-workspace-names-design.md.
    @MainActor
    private static func workspaceRename(
        params: [String: Any],
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let idStr = params["workspaceId"] as? String,
              let id = UUID(uuidString: idStr) else {
            throw RemoteError.bad("workspaceId required (UUID string)")
        }
        guard let raw = params["name"] as? String else {
            throw RemoteError.bad("name required")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else {
            throw RemoteError.bad("name must be 1–80 characters")
        }
        guard let ws = workspaceStore.workspaces.first(where: { $0.id == id }) else {
            throw RemoteError.bad("workspace not found")
        }
        workspaceStore.rename(ws, to: trimmed)
        return [
            "ok": true,
            "workspaceId": id.uuidString,
            "name": trimmed,
            "nameSource": NameSource.named.rawValue,
        ] as [String: Any]
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

        var buildMode: BuildMode? = nil
        if let raw = params["buildMode"] as? String {
            guard let parsed = BuildMode(rawValue: raw) else {
                throw RemoteError.bad("invalid buildMode: \(raw)")
            }
            buildMode = parsed
        }
        let makeProjectDefault = (params["makeProjectDefault"] as? Bool) ?? false

        guard let project = appStore.projects.first(where: { $0.id == projectId }) else {
            throw RemoteError.bad("project not found")
        }
        guard let provider = appStore.providers.first(where: { $0.id == providerId }) else {
            throw RemoteError.bad("provider not found")
        }
        let baseBranch = (params["baseBranch"] as? String) ?? project.defaultBaseBranch
        let userName = NSUserName()

        if makeProjectDefault, let mode = buildMode {
            try appStore.setProjectDefaultBuildMode(projectId: project.id, mode: mode)
        }

        let workspace = try workspaceStore.create(
            project: project,
            name: name,
            baseBranch: baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: userName,
            buildMode: buildMode
        )

        await appStore.bootstrapAllSessions(workspaces: [workspace])

        let resolvedMode = workspace.effectiveBuildMode(
            in: appStore.projects.first(where: { $0.id == project.id }) ?? project
        )

        return [
            "id": workspace.id.uuidString,
            "name": workspace.name,
            "branchName": workspace.branchName,
            "worktreePath": workspace.worktreePath,
            "lifecycleState": workspace.lifecycleState.rawValue,
            "modelId": workspace.modelId,
            "buildMode": resolvedMode.rawValue,
        ]
    }

    // MARK: - workspace.quickCreate

    @MainActor
    private static func workspaceQuickCreate(
        params: [String: Any],
        env: AppEnvironment,
        appStore: AppStore,
        workspaceStore: WorkspaceStore
    ) async throws -> Any? {
        guard let projectIdStr = params["projectId"] as? String,
              let projectId = UUID(uuidString: projectIdStr) else {
            throw RemoteError.bad("projectId required (UUID string)")
        }
        guard let project = appStore.projects.first(where: { $0.id == projectId }) else {
            throw RemoteError.bad("project not found")
        }

        let resolution = workspaceStore.resolveQuickCreateInputs(
            project: project,
            providers: appStore.providers,
            globalDefault: appStore.getGlobalDefault()
        )

        if !resolution.missing.isEmpty {
            // Partial resolution. iOS uses `suggested` to pre-fill the
            // recovery sheet; missing tells it which fields to focus on.
            var suggested: [String: Any] = [
                "name": resolution.name,
                "baseBranch": resolution.baseBranch,
            ]
            if let pid = resolution.providerId { suggested["providerId"] = pid.uuidString }
            if let mid = resolution.modelId { suggested["modelId"] = mid }
            if let bm = resolution.buildMode { suggested["buildMode"] = bm.rawValue }
            return [
                "status": "needs_input",
                "missing": resolution.missing,
                "suggested": suggested,
            ] as [String: Any]
        }

        // Resolution complete — proceed.
        guard let pid = resolution.providerId,
              let provider = appStore.providers.first(where: { $0.id == pid }),
              let modelId = resolution.modelId, !modelId.isEmpty else {
            // Defensive: missing is empty but the unwraps fail — shouldn't
            // happen given the resolver's invariants, but don't proceed
            // with garbage.
            throw RemoteError.bad("resolution incomplete")
        }
        let userName = NSUserName()
        let workspace = try workspaceStore.create(
            project: project,
            name: resolution.name,
            baseBranch: resolution.baseBranch,
            provider: provider,
            modelId: modelId,
            gitUserName: userName,
            buildMode: resolution.buildMode,
            nameSource: .random
        )
        await appStore.bootstrapAllSessions(workspaces: [workspace])

        let resolvedMode = workspace.effectiveBuildMode(
            in: appStore.projects.first(where: { $0.id == project.id }) ?? project
        )

        return [
            "status": "created",
            "workspace": [
                "id": workspace.id.uuidString,
                "name": workspace.name,
                "branchName": workspace.branchName,
                "worktreePath": workspace.worktreePath,
                "lifecycleState": workspace.lifecycleState.rawValue,
                "modelId": workspace.modelId,
                "buildMode": resolvedMode.rawValue,
                "projectId": workspace.projectId.uuidString,
                "baseBranch": workspace.baseBranch,
            ] as [String: Any],
        ] as [String: Any]
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

    // MARK: - fs.list

    /// List immediate subdirectories of a path on the Mac so iOS can drill
    /// into arbitrary folders when adding a project. Hidden entries and
    /// regular files are filtered out. Defaults to `$HOME` when no path
    /// is provided.
    @MainActor
    private static func fsList(params: [String: Any]) async throws -> Any? {
        let raw = (params["path"] as? String)?.trimmingCharacters(in: .whitespaces)
        let path: String = (raw?.isEmpty == false ? raw! :
                            FileManager.default.homeDirectoryForCurrentUser.path)
        do {
            let listing = try RemoteFs.list(path: path)
            return [
                "path": listing.path,
                "parent": (listing.parent as Any?) ?? NSNull(),
                "entries": listing.entries.map { e in
                    [
                        "name": e.name,
                        "path": e.path,
                        "isGitRepo": e.isGitRepo,
                    ] as [String: Any]
                },
            ] as [String: Any]
        } catch {
            throw RemoteError.bad((error as? RemoteFs.ListError)?.errorDescription
                                  ?? error.localizedDescription)
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


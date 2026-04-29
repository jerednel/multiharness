import Foundation

public final class PersistenceService: @unchecked Sendable {
    public let db: Database
    public let dataDir: URL
    public let workspacesDir: URL

    public init(dataDir: URL) throws {
        self.dataDir = dataDir
        self.workspacesDir = dataDir.appendingPathComponent("workspaces", isDirectory: true)
        try FileManager.default.createDirectory(at: workspacesDir, withIntermediateDirectories: true)
        let dbPath = dataDir.appendingPathComponent("state.db").path
        self.db = try Database(path: dbPath)
        try Migrations.apply(db)
    }

    public static func defaultDataDir() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Multiharness", isDirectory: true)
    }

    // MARK: - Projects

    public func upsertProject(_ p: Project) throws {
        try db.executeUpdate(
            """
            INSERT INTO projects (id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark, context_instructions)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              slug=excluded.slug,
              repo_path=excluded.repo_path,
              default_base_branch=excluded.default_base_branch,
              default_provider_id=excluded.default_provider_id,
              default_model_id=excluded.default_model_id,
              default_build_mode=excluded.default_build_mode,
              repo_bookmark=excluded.repo_bookmark,
              context_instructions=excluded.context_instructions;
            """
        ) { st in
            st.bind(1, p.id.uuidString)
            st.bind(2, p.name)
            st.bind(3, p.slug)
            st.bind(4, p.repoPath)
            st.bind(5, p.defaultBaseBranch)
            st.bind(6, p.defaultProviderId?.uuidString)
            st.bind(7, p.defaultModelId)
            st.bind(8, p.defaultBuildMode?.rawValue)
            st.bind(9, p.createdAt)
            st.bind(10, p.repoBookmark)
            st.bind(11, p.contextInstructions)
        }
    }

    public func listProjects() throws -> [Project] {
        try db.query(
            "SELECT id, name, slug, repo_path, default_base_branch, default_provider_id, default_model_id, default_build_mode, created_at, repo_bookmark, context_instructions FROM projects ORDER BY created_at ASC;",
            rowMap: { st in
                Project(
                    id: UUID(uuidString: st.requiredString(0))!,
                    name: st.requiredString(1),
                    slug: st.requiredString(2),
                    repoPath: st.requiredString(3),
                    defaultBaseBranch: st.requiredString(4),
                    defaultProviderId: st.string(5).flatMap { UUID(uuidString: $0) },
                    defaultModelId: st.string(6),
                    defaultBuildMode: st.string(7).flatMap(BuildMode.init(rawValue:)),
                    createdAt: st.requiredDate(8),
                    repoBookmark: st.data(9),
                    contextInstructions: st.string(10) ?? ""
                )
            }
        )
    }

    public func deleteProject(id: UUID) throws {
        try db.executeUpdate("DELETE FROM projects WHERE id = ?;") { st in
            st.bind(1, id.uuidString)
        }
    }

    // MARK: - Providers

    public func upsertProvider(_ p: ProviderRecord) throws {
        try db.executeUpdate(
            """
            INSERT INTO providers (id, name, kind, pi_provider, base_url, default_model_id, keychain_account, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              kind=excluded.kind,
              pi_provider=excluded.pi_provider,
              base_url=excluded.base_url,
              default_model_id=excluded.default_model_id,
              keychain_account=excluded.keychain_account;
            """
        ) { st in
            st.bind(1, p.id.uuidString)
            st.bind(2, p.name)
            st.bind(3, p.kind.rawValue)
            st.bind(4, p.piProvider)
            st.bind(5, p.baseUrl)
            st.bind(6, p.defaultModelId)
            st.bind(7, p.keychainAccount)
            st.bind(8, p.createdAt)
        }
    }

    public func listProviders() throws -> [ProviderRecord] {
        try db.query(
            "SELECT id, name, kind, pi_provider, base_url, default_model_id, keychain_account, created_at FROM providers ORDER BY created_at ASC;",
            rowMap: { st in
                ProviderRecord(
                    id: UUID(uuidString: st.requiredString(0))!,
                    name: st.requiredString(1),
                    kind: ProviderKind(rawValue: st.requiredString(2)) ?? .openaiCompatible,
                    piProvider: st.string(3),
                    baseUrl: st.string(4),
                    defaultModelId: st.string(5),
                    keychainAccount: st.string(6),
                    createdAt: st.requiredDate(7)
                )
            }
        )
    }

    public func deleteProvider(id: UUID) throws {
        try db.executeUpdate("DELETE FROM providers WHERE id = ?;") { st in
            st.bind(1, id.uuidString)
        }
    }

    // MARK: - Workspaces

    public func upsertWorkspace(_ w: Workspace) throws {
        try db.executeUpdate(
            """
            INSERT INTO workspaces (id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name=excluded.name,
              slug=excluded.slug,
              branch_name=excluded.branch_name,
              base_branch=excluded.base_branch,
              worktree_path=excluded.worktree_path,
              lifecycle_state=excluded.lifecycle_state,
              provider_id=excluded.provider_id,
              model_id=excluded.model_id,
              build_mode=excluded.build_mode,
              archived_at=excluded.archived_at,
              name_source=excluded.name_source,
              context_instructions=excluded.context_instructions,
              last_viewed_at=excluded.last_viewed_at;
            """
        ) { st in
            st.bind(1, w.id.uuidString)
            st.bind(2, w.projectId.uuidString)
            st.bind(3, w.name)
            st.bind(4, w.slug)
            st.bind(5, w.branchName)
            st.bind(6, w.baseBranch)
            st.bind(7, w.worktreePath)
            st.bind(8, w.lifecycleState.rawValue)
            st.bind(9, w.providerId.uuidString)
            st.bind(10, w.modelId)
            st.bind(11, w.buildMode?.rawValue)
            st.bind(12, w.createdAt)
            st.bind(13, w.archivedAt)
            st.bind(14, w.nameSource.rawValue)
            st.bind(15, w.contextInstructions)
            st.bind(16, w.lastViewedAt)
        }
    }

    public func listWorkspaces(projectId: UUID? = nil) throws -> [Workspace] {
        let sql: String
        if projectId != nil {
            sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at FROM workspaces WHERE project_id = ? ORDER BY created_at DESC;"
        } else {
            sql = "SELECT id, project_id, name, slug, branch_name, base_branch, worktree_path, lifecycle_state, provider_id, model_id, build_mode, created_at, archived_at, name_source, context_instructions, last_viewed_at FROM workspaces ORDER BY created_at DESC;"
        }
        return try db.query(
            sql,
            bind: { st in
                if let pid = projectId { st.bind(1, pid.uuidString) }
            },
            rowMap: { st in
                Workspace(
                    id: UUID(uuidString: st.requiredString(0))!,
                    projectId: UUID(uuidString: st.requiredString(1))!,
                    name: st.requiredString(2),
                    slug: st.requiredString(3),
                    branchName: st.requiredString(4),
                    baseBranch: st.requiredString(5),
                    worktreePath: st.requiredString(6),
                    lifecycleState: LifecycleState(rawValue: st.requiredString(7)) ?? .inProgress,
                    providerId: UUID(uuidString: st.requiredString(8))!,
                    modelId: st.requiredString(9),
                    buildMode: st.string(10).flatMap(BuildMode.init(rawValue:)),
                    createdAt: st.requiredDate(11),
                    archivedAt: st.date(12),
                    nameSource: st.string(13).flatMap(NameSource.init(rawValue:)) ?? .random,
                    contextInstructions: st.string(14) ?? "",
                    lastViewedAt: st.date(15)
                )
            }
        )
    }

    public func deleteWorkspace(id: UUID) throws {
        try db.executeUpdate("DELETE FROM workspaces WHERE id = ?;") { st in
            st.bind(1, id.uuidString)
        }
    }

    /// Updates `last_viewed_at` for the given workspace to now. Idempotent;
    /// silently no-ops when the id doesn't exist.
    public func markWorkspaceViewed(id: UUID) throws {
        try db.executeUpdate(
            "UPDATE workspaces SET last_viewed_at = ? WHERE id = ?;"
        ) { st in
            st.bind(1, Date())
            st.bind(2, id.uuidString)
        }
    }

    // MARK: - Settings

    public func getSetting(_ key: String) throws -> String? {
        let rows = try db.query(
            "SELECT value FROM settings WHERE key = ?;",
            bind: { $0.bind(1, key) },
            rowMap: { $0.string(0) }
        )
        return rows.first ?? nil
    }

    public func setSetting(_ key: String, value: String) throws {
        try db.executeUpdate(
            "INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        ) { st in
            st.bind(1, key)
            st.bind(2, value)
        }
    }

    // MARK: - JSONL message log

    public func messagesPath(workspaceId: UUID) -> URL {
        workspacesDir
            .appendingPathComponent(workspaceId.uuidString, isDirectory: true)
            .appendingPathComponent("messages.jsonl")
    }
}

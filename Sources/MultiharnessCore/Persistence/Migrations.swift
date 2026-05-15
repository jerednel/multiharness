import Foundation

public struct Migrations {
    private static let v1 = """
        CREATE TABLE IF NOT EXISTS schema_version (
          version INTEGER PRIMARY KEY
        );
        CREATE TABLE IF NOT EXISTS projects (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          slug TEXT NOT NULL UNIQUE,
          repo_path TEXT NOT NULL,
          default_base_branch TEXT NOT NULL DEFAULT 'main',
          default_provider_id TEXT,
          default_model_id TEXT,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS providers (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          kind TEXT NOT NULL,
          pi_provider TEXT,
          base_url TEXT,
          default_model_id TEXT,
          keychain_account TEXT,
          created_at INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS workspaces (
          id TEXT PRIMARY KEY,
          project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
          name TEXT NOT NULL,
          slug TEXT NOT NULL,
          branch_name TEXT NOT NULL,
          base_branch TEXT NOT NULL,
          worktree_path TEXT NOT NULL,
          lifecycle_state TEXT NOT NULL,
          provider_id TEXT NOT NULL REFERENCES providers(id),
          model_id TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          archived_at INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_workspaces_project ON workspaces(project_id);
        CREATE INDEX IF NOT EXISTS idx_workspaces_lifecycle ON workspaces(lifecycle_state);
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        );
        """

    public static let all: [String] = [
        v1,
        // v2: persist security-scoped bookmark for the repo path
        "ALTER TABLE projects ADD COLUMN repo_bookmark BLOB;",
        // v3: build mode toggle
        """
        ALTER TABLE projects ADD COLUMN default_build_mode TEXT;
        ALTER TABLE workspaces ADD COLUMN build_mode TEXT;
        """,
        // v4: track whether a workspace is still using its random adjective-noun
        // name so the sidecar knows to AI-rename it after the first prompt.
        "ALTER TABLE workspaces ADD COLUMN name_source TEXT NOT NULL DEFAULT 'random';",
        // v5: per-project and per-workspace context injection
        """
        ALTER TABLE projects   ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
        ALTER TABLE workspaces ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
        """,
        // v6: per-workspace last-viewed timestamp powering the unseen dot.
        // Backfill existing rows to "now" so users don't see a flood of dots
        // on first launch after upgrade.
        """
        ALTER TABLE workspaces ADD COLUMN last_viewed_at INTEGER;
        UPDATE workspaces SET last_viewed_at = CAST(strftime('%s','now') AS INTEGER) * 1000;
        """,
        // v7: opt-in QA reviewer pass. Project-level columns are the
        // defaults a new workspace inherits; workspace-level columns are
        // explicit overrides. `qa_enabled` is nullable on workspaces so
        // we can distinguish "no opinion → use project default" from
        // "explicit opt-in" and "explicit opt-out".
        """
        ALTER TABLE projects   ADD COLUMN default_qa_enabled INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE projects   ADD COLUMN default_qa_provider_id TEXT;
        ALTER TABLE projects   ADD COLUMN default_qa_model_id TEXT;
        ALTER TABLE workspaces ADD COLUMN qa_enabled INTEGER;
        ALTER TABLE workspaces ADD COLUMN qa_provider_id TEXT;
        ALTER TABLE workspaces ADD COLUMN qa_model_id TEXT;
        """,
        // v8: opt-in auto-apply loop. When on, blocking QA findings are
        // automatically fed back to the primary as a new prompt (capped
        // at 3 iterations per cycle — see App.swift). Off by default.
        // Same inheritance shape as v7: project default + nullable
        // workspace override.
        """
        ALTER TABLE projects   ADD COLUMN default_qa_auto_apply INTEGER NOT NULL DEFAULT 0;
        ALTER TABLE workspaces ADD COLUMN qa_auto_apply INTEGER;
        """,
    ]

    public static func apply(_ db: Database) throws {
        try db.exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER PRIMARY KEY);")
        let current: Int = try db.query(
            "SELECT IFNULL(MAX(version), 0) FROM schema_version;",
            rowMap: { Int($0.int64(0) ?? 0) }
        ).first ?? 0
        for (idx, sql) in all.enumerated() {
            let target = idx + 1
            if target > current {
                try db.exec(sql)
                try db.executeUpdate("INSERT INTO schema_version (version) VALUES (?);") { st in
                    st.bind(1, Int64(target))
                }
            }
        }
    }
}

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

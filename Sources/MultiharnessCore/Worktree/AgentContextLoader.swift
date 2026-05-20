import Foundation

/// Reads the worktree-root agent-orientation file. Prefers `CLAUDE.md`,
/// falls back to `AGENTS.md`, returns nil if neither exists. No traversal
/// beyond the worktree root by design — see the global
/// `auto_load_agent_context` setting in AppStore.
public enum AgentContextLoader {
    public static let candidateFilenames: [String] = ["CLAUDE.md", "AGENTS.md"]

    public static func load(worktreePath: String) -> String? {
        for name in candidateFilenames {
            let path = (worktreePath as NSString).appendingPathComponent(name)
            if let text = try? String(contentsOfFile: path, encoding: .utf8),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
        }
        return nil
    }

    /// Name of the file that `load` would have used (e.g. "CLAUDE.md"),
    /// or nil if neither candidate is present in the worktree root. Used
    /// by the Context tab banner to tell the user which file is in the
    /// agent's system prompt without reading the bytes twice.
    public static func resolvedFilename(worktreePath: String) -> String? {
        for name in candidateFilenames {
            let path = (worktreePath as NSString).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: path) {
                return name
            }
        }
        return nil
    }
}

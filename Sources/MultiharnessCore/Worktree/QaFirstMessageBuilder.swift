import Foundation
import MultiharnessClient

/// Builds the seed message the Mac sends to the QA agent as its first
/// (and usually only) prompt. The agent uses this to orient — it then
/// pulls anything else it needs through its read-only tools (read_file,
/// grep, bash, etc.).
///
/// Construction lives Mac-side because we want to reuse the existing
/// `WorktreeService` shell helpers (which already know about
/// security-scoped bookmarks for TCC-protected paths) and let the Mac
/// own the truncation policy. See spec §9.
///
/// The shape:
///
/// ```
/// The primary agent just finished work in this workspace.
///
/// Branch: <branchName>
/// Base:   <baseBranch>
///
/// Most recent user request:
/// <last user prompt>
///
/// Primary agent's final summary (its last assistant turn):
/// <last assistant message>
///
/// Diff vs <baseBranch>:
/// <git diff base...HEAD, truncated>
///
/// Please review.
/// ```
///
/// Diff truncation: capped at ~50,000 characters (spec §5). Anything
/// longer is truncated with a one-line note; the QA agent can pull more
/// via `read_file` if it needs to.
public enum QaFirstMessageBuilder {
    /// Hard cap on the embedded diff in characters. Picked to fit
    /// comfortably inside a single LLM turn for all the providers we
    /// support today, with headroom for the surrounding prose.
    public static let diffCharacterCap = 50_000

    public struct Inputs {
        public let branchName: String
        public let baseBranch: String
        public let lastUserPrompt: String?
        public let lastAssistantMessage: String?
        public let diffVsBase: String

        public init(
            branchName: String,
            baseBranch: String,
            lastUserPrompt: String?,
            lastAssistantMessage: String?,
            diffVsBase: String
        ) {
            self.branchName = branchName
            self.baseBranch = baseBranch
            self.lastUserPrompt = lastUserPrompt
            self.lastAssistantMessage = lastAssistantMessage
            self.diffVsBase = diffVsBase
        }
    }

    public static func build(_ inputs: Inputs) -> String {
        var out = "The primary agent just finished work in this workspace.\n\n"
        out += "Branch: \(inputs.branchName)\n"
        out += "Base:   \(inputs.baseBranch)\n\n"
        if let req = inputs.lastUserPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !req.isEmpty
        {
            out += "Most recent user request:\n\(req)\n\n"
        }
        if let resp = inputs.lastAssistantMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resp.isEmpty
        {
            out += "Primary agent's final summary (its last assistant turn):\n\(resp)\n\n"
        }
        let (truncated, omitted) = truncateDiff(inputs.diffVsBase)
        out += "Diff vs \(inputs.baseBranch):\n"
        if truncated.isEmpty {
            out += "(no diff — the worktree matches the base branch)\n"
        } else {
            out += truncated
            if !truncated.hasSuffix("\n") { out += "\n" }
            if omitted {
                out += "\n…(diff truncated at \(diffCharacterCap) characters; "
                out += "use read_file to inspect specific files in full)\n"
            }
        }
        out += "\nPlease review."
        return out
    }

    /// Convenience that builds the inputs by pulling the diff from the
    /// passed-in worktree service and extracting the last turns from a
    /// rehydrated `ConversationTurn` list. Returns an empty diff
    /// (rather than throwing) when `git diff` fails — the QA agent
    /// still gets a useful seed message, and can shell out itself if
    /// the diff is critical.
    public static func build(
        worktree: WorktreeService,
        worktreePath: String,
        branchName: String,
        baseBranch: String,
        turns: [ConversationTurn]
    ) -> String {
        let diff = (try? worktree.diff(
            worktreePath: worktreePath,
            baseBranch: baseBranch,
            file: nil
        )) ?? ""
        return build(Inputs(
            branchName: branchName,
            baseBranch: baseBranch,
            lastUserPrompt: lastUserText(in: turns),
            lastAssistantMessage: lastAssistantText(in: turns),
            diffVsBase: diff
        ))
    }

    // MARK: - Helpers

    /// Truncate the diff to `diffCharacterCap` characters, returning the
    /// (possibly truncated) body and a flag indicating whether it was.
    /// Truncation respects line boundaries — we don't want to dump the
    /// reviewer into the middle of a `@@ -1,2 +3,4 @@` header.
    public static func truncateDiff(_ diff: String) -> (body: String, omitted: Bool) {
        if diff.count <= diffCharacterCap {
            return (diff, false)
        }
        let cutoff = diff.index(diff.startIndex, offsetBy: diffCharacterCap)
        let prefix = String(diff[..<cutoff])
        // Trim back to the last newline so we don't end mid-line.
        if let lastNewline = prefix.lastIndex(of: "\n") {
            return (String(prefix[...lastNewline]), true)
        }
        return (prefix, true)
    }

    /// Last user turn's text (the user's most recent prompt), or nil
    /// if no user turns are present.
    public static func lastUserText(in turns: [ConversationTurn]) -> String? {
        for t in turns.reversed() where t.role == .user && !t.text.isEmpty {
            return t.text
        }
        return nil
    }

    /// Last assistant turn's text, restricted to "build" turns (not QA
    /// findings cards). Used to give the QA agent the primary's own
    /// claim of what it did — feeding it the previous QA's summary
    /// would be circular.
    public static func lastAssistantText(in turns: [ConversationTurn]) -> String? {
        for t in turns.reversed() where t.role == .assistant && !t.text.isEmpty {
            return t.text
        }
        return nil
    }
}

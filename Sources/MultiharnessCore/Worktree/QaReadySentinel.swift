import Foundation

/// Token the primary agent emits at the end of a message when it
/// believes the requested feature is complete. The Mac watches for
/// this on `agent_end` and, when seen + QA is configured, kicks off a
/// QA review automatically. Must match `QA_READY_SENTINEL` in
/// `sidecar/src/prompts.ts`.
public enum QaReadySentinel {
    public static let token = "<<MULTIHARNESS_QA_READY>>"

    /// Returns true when `text` contains the sentinel anywhere.
    public static func isPresent(in text: String) -> Bool {
        text.contains(token)
    }

    /// Returns `text` with every occurrence of the sentinel removed,
    /// along with any trailing whitespace/blank lines the model left
    /// behind. Cosmetic — the goal is to keep the rendered transcript
    /// clean. The raw JSONL on disk still contains the token, which is
    /// fine: it's the wire log, not the user-facing transcript.
    public static func stripped(from text: String) -> String {
        guard text.contains(token) else { return text }
        // Strip the token (handling cases where the model put it on its
        // own line with trailing newline) and then trim trailing
        // whitespace/newlines off the end of the message.
        var out = text.replacingOccurrences(of: token + "\n", with: "")
        out = out.replacingOccurrences(of: token, with: "")
        while let last = out.last, last == "\n" || last == " " || last == "\t" {
            out.removeLast()
        }
        return out
    }
}

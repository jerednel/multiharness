import Foundation
import MultiharnessClient

/// Builds the follow-up prompt the Mac sends to the primary agent when
/// QA reports `blocking_issues` and the auto-apply loop is enabled.
///
/// Kept simple by design — the QA verdict + findings are already in the
/// transcript (the `qa_findings` event renders a structured card),
/// which means the primary agent's context window can already see
/// them. The prompt here is mostly a "please act on them now" nudge.
/// Format chosen to stay parseable and short.
public enum QaAutoApplyPromptBuilder {
    /// Per-finding line length cap; keeps the prompt readable when QA
    /// drops a wall of text into a single finding.
    public static let messageCap = 600

    public static func build(
        verdict: QaVerdict,
        summary: String,
        findings: [QaFinding],
        cycleIndex: Int,
        cycleCap: Int
    ) -> String {
        var out = "The QA reviewer returned **\(verdict.label.lowercased())**.\n\n"
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            out += "Summary:\n\(trimmedSummary)\n\n"
        }
        let blockers = findings.filter { $0.severity == .blocker }
        if !blockers.isEmpty {
            out += "Blocking findings:\n"
            for f in blockers {
                out += "- \(format(finding: f))\n"
            }
            out += "\n"
        }
        out += "Please fix the blocking findings above."
        // Surface the remaining iteration budget so the model can size
        // its response — fixing everything in one go vs. asking for
        // help when the next QA pass would exhaust the cycle cap.
        let remaining = max(0, cycleCap - cycleIndex)
        if remaining == 0 {
            out += " This is the final auto-QA cycle for this task; "
            out += "after this run the loop will stop regardless of QA's next verdict."
        } else {
            out += " (Auto-QA will re-run after you signal completion; "
            out += "\(remaining) cycle\(remaining == 1 ? "" : "s") remaining.)"
        }
        return out
    }

    private static func format(finding f: QaFinding) -> String {
        var location = ""
        if let file = f.file?.trimmingCharacters(in: .whitespacesAndNewlines), !file.isEmpty {
            location = file
            if let line = f.line { location += ":\(line)" }
            location += " — "
        }
        let msg = f.message.count > messageCap
            ? String(f.message.prefix(messageCap)) + "…"
            : f.message
        return location + msg
    }
}

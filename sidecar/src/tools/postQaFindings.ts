import { Type, type Static } from "@mariozechner/pi-ai";
import type { AgentTool } from "@mariozechner/pi-agent-core";

/// Severity levels a QA finding can carry. Ordered loosely from
/// least → most urgent so UI renderers can sort if they choose to.
export const QA_FINDING_SEVERITIES = ["info", "warning", "blocker"] as const;
export type QaFindingSeverity = typeof QA_FINDING_SEVERITIES[number];

/// Top-level verdict on the review. `pass` ≈ ship it; `minor_issues`
/// ≈ ship-able but noted; `blocking_issues` ≈ don't ship.
export const QA_VERDICTS = ["pass", "minor_issues", "blocking_issues"] as const;
export type QaVerdict = typeof QA_VERDICTS[number];

export type QaFinding = {
  severity: QaFindingSeverity;
  file?: string;
  line?: number;
  message: string;
};

export type QaFindingsPayload = {
  verdict: QaVerdict;
  summary: string;
  findings: QaFinding[];
};

/// Called by the tool when the QA agent invokes it. The runner uses
/// this to emit a `qa_findings` event on the WebSocket so the UI can
/// render the structured card.
export type QaFindingsSink = (payload: QaFindingsPayload) => void;

// Each literal needs to be written out explicitly so `Type.Union` sees a
// tuple of `TLiteral<"…">` and `Static<…>` can resolve the union to the
// narrow string-literal type (rather than `never`, which is what a
// widened `TLiteral<string>[]` collapses to).
const FindingSchema = Type.Object({
  severity: Type.Union([
    Type.Literal("info"),
    Type.Literal("warning"),
    Type.Literal("blocker"),
  ]),
  file: Type.Optional(Type.String()),
  line: Type.Optional(Type.Integer()),
  message: Type.String(),
});

const Params = Type.Object({
  verdict: Type.Union(
    [
      Type.Literal("pass"),
      Type.Literal("minor_issues"),
      Type.Literal("blocking_issues"),
    ],
    {
      description:
        "Top-level verdict. `pass` = no issues; `minor_issues` = ship-able with noted concerns; `blocking_issues` = do not ship.",
    },
  ),
  summary: Type.String({
    description:
      "Plain-text 1-3 paragraph summary of the review. No markdown — the renderer treats this as plain text.",
  }),
  findings: Type.Optional(
    Type.Array(FindingSchema, {
      description:
        "Optional structured findings: severity (info/warning/blocker), optional file + line, message. Use this for specific issues so the UI can link to files; put the high-level narrative in `summary`.",
    }),
  ),
});

type ParamsT = Static<typeof Params>;

/// Build the `post_qa_findings` tool. The `sink` callback is invoked
/// synchronously inside `execute` with the parsed payload — the QA
/// runner wires it to emit a `qa_findings` event on the WebSocket bus.
///
/// Returns `{ ok: true }` so the agent perceives a clean tool result
/// and stops (the system prompt instructs it to call this exactly once
/// and stop, but we don't rely on that alone — the structured payload
/// also gives the runner a signal that the review is complete if it
/// ever wants to dispose early).
export function postQaFindingsTool(sink: QaFindingsSink): AgentTool<typeof Params> {
  return {
    name: "post_qa_findings",
    label: "Post QA findings",
    description:
      "Call exactly once when your review is complete. Reports the verdict, a plain-text summary, and an optional list of structured findings. After calling this, stop.",
    parameters: Params,
    execute: async (_id, raw) => {
      const args = raw as ParamsT;
      const findings: QaFinding[] = (args.findings ?? []).map((f) => ({
        severity: f.severity,
        file: f.file,
        line: f.line,
        message: f.message,
      }));
      const payload: QaFindingsPayload = {
        verdict: args.verdict,
        summary: args.summary,
        findings,
      };
      sink(payload);
      return {
        content: [
          {
            type: "text",
            text: `findings recorded: ${args.verdict}`,
          },
        ],
        details: payload,
      };
    },
  };
}

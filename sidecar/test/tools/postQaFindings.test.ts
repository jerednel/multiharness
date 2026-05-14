import { describe, it, expect } from "bun:test";
import { postQaFindingsTool, type QaFindingsPayload } from "../../src/tools/postQaFindings.js";

describe("post_qa_findings", () => {
  it("invokes the sink with the supplied verdict + summary + findings", async () => {
    const captured: QaFindingsPayload[] = [];
    const tool = postQaFindingsTool((p) => captured.push(p));
    await tool.execute("call-1", {
      verdict: "minor_issues",
      summary: "Looks mostly correct but missing a test.",
      findings: [
        { severity: "warning", file: "src/foo.ts", line: 12, message: "TODO left in." },
      ],
    });
    expect(captured).toHaveLength(1);
    const first = captured[0]!;
    expect(first.verdict).toBe("minor_issues");
    expect(first.summary).toContain("missing a test");
    expect(first.findings).toHaveLength(1);
    expect(first.findings[0]).toMatchObject({
      severity: "warning",
      file: "src/foo.ts",
      line: 12,
      message: "TODO left in.",
    });
  });

  it("treats omitted findings as an empty array", async () => {
    const captured: QaFindingsPayload[] = [];
    const tool = postQaFindingsTool((p) => captured.push(p));
    await tool.execute("call-1", {
      verdict: "pass",
      summary: "All good.",
    } as any);
    expect(captured[0]!.findings).toEqual([]);
  });

  it("returns a textual tool result confirming the verdict", async () => {
    const tool = postQaFindingsTool(() => {});
    const r = await tool.execute("call-1", {
      verdict: "blocking_issues",
      summary: "broken",
    } as any);
    expect(r.content[0]).toMatchObject({ type: "text" });
    expect((r.content[0] as { text: string }).text).toContain("blocking_issues");
  });

  it("supports all three verdicts", async () => {
    const captured: QaFindingsPayload[] = [];
    const tool = postQaFindingsTool((p) => captured.push(p));
    const verdicts: Array<"pass" | "minor_issues" | "blocking_issues"> = [
      "pass",
      "minor_issues",
      "blocking_issues",
    ];
    for (const v of verdicts) {
      await tool.execute("call", { verdict: v, summary: "x" } as any);
    }
    expect(captured.map((p) => p.verdict)).toEqual([
      "pass",
      "minor_issues",
      "blocking_issues",
    ]);
  });

  it("preserves all severity levels in passthrough", async () => {
    const captured: QaFindingsPayload[] = [];
    const tool = postQaFindingsTool((p) => captured.push(p));
    await tool.execute("call-1", {
      verdict: "minor_issues",
      summary: "x",
      findings: [
        { severity: "info", message: "FYI" },
        { severity: "warning", message: "soft issue" },
        { severity: "blocker", message: "hard issue" },
      ],
    });
    expect(captured[0]!.findings.map((f) => f.severity)).toEqual([
      "info",
      "warning",
      "blocker",
    ]);
  });
});

import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, readFileSync, realpathSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { QaRunner, makeQaFindingsEvent } from "../src/qaRunner.js";
import type { EventSink } from "../src/agentSession.js";

let dataDir: string;
let worktree: string;
beforeEach(() => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-qa-data-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-qa-wt-")));
});

// Unreachable LM-Studio-style endpoint — the agent will error out
// before any tools or model output get involved, which is what we want:
// it lets us observe the session was constructed with the right shape
// (jsonl path, qa mode, etc.) without needing a live model.
const cfg = {
  kind: "openai-compatible" as const,
  modelId: "x",
  baseUrl: "http://127.0.0.1:1/v1",
};

describe("makeQaFindingsEvent", () => {
  it("translates a tool payload into the wire event shape", () => {
    const ev = makeQaFindingsEvent({
      verdict: "minor_issues",
      summary: "Looks ok but missing a test.",
      findings: [
        { severity: "warning", file: "x.ts", line: 1, message: "TODO" },
      ],
    });
    expect(ev.type).toBe("qa_findings");
    expect(ev.verdict).toBe("minor_issues");
    expect(ev.summary).toContain("missing a test");
    expect(ev.findings).toHaveLength(1);
  });
});

describe("QaRunner", () => {
  it("writes its JSONL into the same workspace path as the primary session", async () => {
    // Same path as `AgentRegistry.create` uses (spec §4): the QA
    // session shares the workspace's append-only log. Verify by
    // running once and confirming the file exists at the canonical
    // workspaces/<id>/messages.jsonl path.
    const wsId = "ws-qa-1";
    const events: { type: string }[] = [];
    const sink: EventSink = (_w, ev) => {
      events.push(ev as unknown as { type: string });
    };
    const runner = new QaRunner(dataDir, sink);
    // We expect this to throw eventually (unreachable provider), but
    // not before AgentSession is constructed and starts writing. The
    // catch lets us inspect the on-disk state.
    try {
      await runner.run({
        workspaceId: wsId,
        projectId: "p1",
        worktreePath: worktree,
        providerConfig: cfg,
        qaPromptText: "review this",
      });
    } catch {
      // expected — model is unreachable
    }
    const jsonlPath = join(dataDir, "workspaces", wsId, "messages.jsonl");
    expect(existsSync(jsonlPath)).toBe(true);
  });

  it("emits agent_start carrying kind:\"qa\"", async () => {
    const wsId = "ws-qa-2";
    const captured: { type: string; kind?: string }[] = [];
    const sink: EventSink = (_w, ev) => {
      captured.push(ev as unknown as { type: string; kind?: string });
    };
    const runner = new QaRunner(dataDir, sink);
    try {
      await runner.run({
        workspaceId: wsId,
        projectId: "p1",
        worktreePath: worktree,
        providerConfig: cfg,
        qaPromptText: "review",
      });
    } catch {
      // expected
    }
    const start = captured.find((e) => e.type === "agent_start");
    expect(start).toBeDefined();
    expect(start?.kind).toBe("qa");
  });

  it("persists qa-tagged agent_start to the JSONL log", async () => {
    const wsId = "ws-qa-3";
    const runner = new QaRunner(dataDir, () => {});
    try {
      await runner.run({
        workspaceId: wsId,
        projectId: "p1",
        worktreePath: worktree,
        providerConfig: cfg,
        qaPromptText: "review",
      });
    } catch {
      // expected
    }
    const jsonlPath = join(dataDir, "workspaces", wsId, "messages.jsonl");
    const text = readFileSync(jsonlPath, "utf8");
    // History rehydration on the Mac groups turns by the qa-tagged
    // agent_start, so the kind field must survive to disk.
    const lines = text.split("\n").filter(Boolean);
    const startLine = lines.find((l) => l.includes('"type":"agent_start"'));
    expect(startLine).toBeDefined();
    expect(startLine).toContain('"kind":"qa"');
  });

  it("findingsSink → makeQaFindingsEvent → sink delivers a qa_findings event", async () => {
    // Direct mapping check: simulate the post_qa_findings tool by
    // invoking the sink with the shape the runner installs internally.
    // (The end-to-end "agent calls the tool" path needs a live model;
    // covered manually + in the unit test for postQaFindingsTool.)
    const wsId = "ws-qa-4";
    const captured: { type: string }[] = [];
    const sink: EventSink = (_w, ev) => {
      captured.push(ev as unknown as { type: string });
    };
    // Bypass run() — we only care that the mapping is right.
    const ev = makeQaFindingsEvent({
      verdict: "pass",
      summary: "All good.",
      findings: [],
    });
    sink(wsId, ev as unknown as Parameters<EventSink>[1]);
    expect(captured).toHaveLength(1);
    expect(captured[0]!.type).toBe("qa_findings");
  });
});

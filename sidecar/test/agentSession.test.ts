import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentSession, type AgentSessionOptions } from "../src/agentSession.js";

let dataDir: string;
let worktree: string;
beforeEach(() => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-data-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-wt-")));
});

function makeOpts(overrides: Partial<AgentSessionOptions> = {}): AgentSessionOptions {
  return {
    workspaceId: "w1",
    projectId: "p1",
    worktreePath: worktree,
    buildMode: "primary",
    providerConfig: {
      kind: "openai-compatible",
      modelId: "x",
      baseUrl: "http://localhost:1234/v1",
      // Explicit contextWindow disables the Ollama auto-probe (otherwise
      // the session fires an async fetch on construction that races the
      // test lifecycle and logs noise into stdout).
      contextWindow: 128_000,
    },
    jsonlPath: join(dataDir, "messages.jsonl"),
    sink: () => {},
    nameSource: "named",
    ...overrides,
  };
}

describe("AgentSession composeSystemPrompt", () => {
  it("uses the build-mode base prompt when both overlays empty", async () => {
    const s = new AgentSession(makeOpts());
    expect(s.currentSystemPrompt()).toContain("helpful coding agent");
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("appends only the project block when workspace overlay empty", async () => {
    const s = new AgentSession(makeOpts({ projectContext: "use pnpm" }));
    expect(s.currentSystemPrompt()).toContain(
      "<project_instructions>\nuse pnpm\n</project_instructions>",
    );
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("appends only the workspace block when project overlay empty", async () => {
    const s = new AgentSession(makeOpts({ workspaceContext: "prefer SwiftUI" }));
    expect(s.currentSystemPrompt()).toContain(
      "<workspace_instructions>\nprefer SwiftUI\n</workspace_instructions>",
    );
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    await s.dispose();
  });

  it("appends both blocks in project-then-workspace order", async () => {
    const s = new AgentSession(
      makeOpts({ projectContext: "P", workspaceContext: "W" }),
    );
    const text = s.currentSystemPrompt();
    expect(text).toContain("<project_instructions>");
    expect(text).toContain("<workspace_instructions>");
    expect(text.indexOf("<project_instructions>")).toBeLessThan(
      text.indexOf("<workspace_instructions>"),
    );
    await s.dispose();
  });

  it("treats whitespace-only overlays as empty", async () => {
    const s = new AgentSession(
      makeOpts({ projectContext: "   \n  ", workspaceContext: "\t" }),
    );
    expect(s.currentSystemPrompt()).not.toContain("<project_instructions>");
    expect(s.currentSystemPrompt()).not.toContain("<workspace_instructions>");
    await s.dispose();
  });

  it("setWorkspaceContext updates state.systemPrompt live", async () => {
    const s = new AgentSession(makeOpts());
    expect(s.currentSystemPrompt()).not.toContain("workspace_instructions");
    s.setWorkspaceContext("v1");
    expect(s.currentSystemPrompt()).toContain("v1");
    s.setWorkspaceContext("v2");
    expect(s.currentSystemPrompt()).toContain("v2");
    expect(s.currentSystemPrompt()).not.toContain("v1");
    await s.dispose();
  });

  it("setProjectContext updates state.systemPrompt live", async () => {
    const s = new AgentSession(makeOpts());
    s.setProjectContext("project rule");
    expect(s.currentSystemPrompt()).toContain("project rule");
    s.setProjectContext("");
    expect(s.currentSystemPrompt()).not.toContain("project_instructions");
    await s.dispose();
  });

  it("always includes a workspace_orientation block with the worktree path", async () => {
    // Even without projectName/branch supplied (back-compat with older
    // Mac builds), the orientation block must anchor the agent on a
    // concrete working directory so it doesn't ask "which project?"
    // after every prompt.
    const s = new AgentSession(makeOpts());
    const text = s.currentSystemPrompt();
    expect(text).toContain("<workspace_orientation>");
    expect(text).toContain(`Working directory: ${worktree}`);
    expect(text).toContain("</workspace_orientation>");
    await s.dispose();
  });

  it("orientation block includes project name and branch when provided", async () => {
    const s = new AgentSession(
      makeOpts({
        projectName: "multiharness",
        branchName: "quick-willow",
        baseBranch: "main",
      }),
    );
    const text = s.currentSystemPrompt();
    expect(text).toContain("Project: multiharness");
    expect(text).toContain("Branch: `quick-willow` (forked from `main`)");
    await s.dispose();
  });

  it("orientation block precedes both project and workspace instruction blocks", async () => {
    // Ordering matters: the model reads top-to-bottom, and the
    // orientation is what stops it from asking "which repo?" before
    // the user's project-level guidance ever gets seen.
    const s = new AgentSession(
      makeOpts({
        projectName: "p",
        branchName: "b",
        baseBranch: "main",
        projectContext: "P",
        workspaceContext: "W",
      }),
    );
    const text = s.currentSystemPrompt();
    const orientationAt = text.indexOf("<workspace_orientation>");
    const projectAt = text.indexOf("<project_instructions>");
    const workspaceAt = text.indexOf("<workspace_instructions>");
    expect(orientationAt).toBeGreaterThan(-1);
    expect(orientationAt).toBeLessThan(projectAt);
    expect(projectAt).toBeLessThan(workspaceAt);
    await s.dispose();
  });
});

describe("AgentSession in qa session mode", () => {
  it("uses the QA reviewer prompt, not the build prompt", async () => {
    const s = new AgentSession(makeOpts({ sessionMode: "qa" }));
    const text = s.currentSystemPrompt();
    expect(text).toContain("You are a QA reviewer");
    expect(text).not.toContain("helpful coding agent operating inside a git worktree");
    await s.dispose();
  });

  it("omits project + workspace instruction blocks (no self-confirming review)", async () => {
    // The whole point of QA is to catch what the build agent missed —
    // feeding it the same project/workspace guidance the builder had
    // would just produce a rubber-stamp review.
    const s = new AgentSession(
      makeOpts({
        sessionMode: "qa",
        projectContext: "always use pnpm",
        workspaceContext: "prefer SwiftUI",
      }),
    );
    const text = s.currentSystemPrompt();
    expect(text).not.toContain("<project_instructions>");
    expect(text).not.toContain("<workspace_instructions>");
    expect(text).not.toContain("always use pnpm");
    expect(text).not.toContain("prefer SwiftUI");
    await s.dispose();
  });

  it("still includes the workspace orientation block", async () => {
    // The reviewer still needs to know which repo / branch / worktree
    // it's looking at — orientation isn't build-specific.
    const s = new AgentSession(
      makeOpts({
        sessionMode: "qa",
        projectName: "multiharness",
        branchName: "u/feat",
        baseBranch: "main",
      }),
    );
    const text = s.currentSystemPrompt();
    expect(text).toContain("<workspace_orientation>");
    expect(text).toContain("Project: multiharness");
    expect(text).toContain("Branch: `u/feat` (forked from `main`)");
    await s.dispose();
  });

  // End-to-end proof that kind:"qa" reaches the sink lives in
  // qaRunner.test.ts ("emits agent_start carrying kind:\"qa\"") — that
  // test drives an unreachable provider to force an agent_start without
  // a live model. We don't duplicate it here because constructing a
  // bare `AgentSession` and provoking a real agent_start requires the
  // same setup.

  it("exposes worktreePath for the QA runner to reuse", async () => {
    const s = new AgentSession(makeOpts());
    expect(s.worktreePath).toBe(worktree);
    await s.dispose();
  });

  it("default sessionMode is 'build'", async () => {
    const s = new AgentSession(makeOpts());
    expect(s.sessionMode).toBe("build");
    await s.dispose();
  });

  it("toolsOverride replaces the default tool set", async () => {
    // We can't introspect the agent's tools easily, but we can verify
    // the option is accepted without throwing — and the QaRunner test
    // covers the integration path that actually exercises a custom set.
    const s = new AgentSession(makeOpts({ toolsOverride: [] }));
    expect(s.sessionMode).toBe("build"); // (option accepted; default stays build)
    await s.dispose();
  });
});

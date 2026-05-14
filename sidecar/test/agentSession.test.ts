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

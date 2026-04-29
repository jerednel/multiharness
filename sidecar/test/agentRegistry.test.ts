import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { AgentRegistry } from "../src/agentRegistry.js";

let dataDir: string;
let worktree: string;
beforeEach(() => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-data-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-wt-")));
});

const cfg = {
  kind: "openai-compatible" as const,
  modelId: "x",
  baseUrl: "http://localhost:1234/v1",
};

describe("AgentRegistry", () => {
  it("rejects duplicate create for same workspace", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "w1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    await expect(
      reg.create({
        workspaceId: "w1",
        projectId: "p1",
        worktreePath: worktree,
        buildMode: "primary",
        providerConfig: cfg,
      }),
    ).rejects.toThrow(/already exists/);
    await reg.disposeAll();
  });

  it("dispose removes a session", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "w1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    expect(reg.list()).toContain("w1");
    await reg.dispose("w1");
    expect(reg.list()).not.toContain("w1");
  });

  it("applyProjectContext updates only sessions in matching project", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "wA1",
      projectId: "pA",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    await reg.create({
      workspaceId: "wA2",
      projectId: "pA",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    await reg.create({
      workspaceId: "wB1",
      projectId: "pB",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    reg.applyProjectContext("pA", "use pnpm");
    expect(reg.get("wA1").currentSystemPrompt()).toContain("use pnpm");
    expect(reg.get("wA2").currentSystemPrompt()).toContain("use pnpm");
    expect(reg.get("wB1").currentSystemPrompt()).not.toContain("use pnpm");
    await reg.disposeAll();
  });

  it("applyWorkspaceContext updates a single session", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "w1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    reg.applyWorkspaceContext("w1", "prefer SwiftUI");
    expect(reg.get("w1").currentSystemPrompt()).toContain("prefer SwiftUI");
    expect(reg.get("w1").currentSystemPrompt()).toContain("workspace_instructions");
    await reg.disposeAll();
  });

  it("applyWorkspaceContext on missing session is a no-op", () => {
    const reg = new AgentRegistry(dataDir, () => {});
    expect(() => reg.applyWorkspaceContext("none", "x")).not.toThrow();
  });
});

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

describe("AgentRegistry", () => {
  it("rejects duplicate create for same workspace", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "w1",
      worktreePath: worktree,
      systemPrompt: "you are helpful",
      providerConfig: {
        kind: "openai-compatible",
        modelId: "x",
        baseUrl: "http://localhost:1234/v1",
      },
    });
    await expect(
      reg.create({
        workspaceId: "w1",
        worktreePath: worktree,
        systemPrompt: "y",
        providerConfig: {
          kind: "openai-compatible",
          modelId: "x",
          baseUrl: "http://localhost:1234/v1",
        },
      }),
    ).rejects.toThrow(/already exists/);
    await reg.disposeAll();
  });

  it("dispose removes a session", async () => {
    const reg = new AgentRegistry(dataDir, () => {});
    await reg.create({
      workspaceId: "w1",
      worktreePath: worktree,
      systemPrompt: "y",
      providerConfig: {
        kind: "openai-compatible",
        modelId: "x",
        baseUrl: "http://localhost:1234/v1",
      },
    });
    expect(reg.list()).toContain("w1");
    await reg.dispose("w1");
    expect(reg.list()).not.toContain("w1");
  });
});

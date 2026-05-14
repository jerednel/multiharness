import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Dispatcher } from "../src/dispatcher.js";
import { AgentRegistry } from "../src/agentRegistry.js";
import { OAuthStore } from "../src/oauthStore.js";
import { Relay } from "../src/relay.js";
import { WorkspaceActivityTracker } from "../src/workspaceActivity.js";
import { registerMethods } from "../src/methods.js";

let dataDir: string;
let worktree: string;
beforeEach(() => {
  dataDir = realpathSync(mkdtempSync(join(tmpdir(), "mh-meth-")));
  worktree = realpathSync(mkdtempSync(join(tmpdir(), "mh-meth-wt-")));
});

function makeStack() {
  const tracker = new WorkspaceActivityTracker(dataDir);
  const events: { type: string; workspaceId?: string }[] = [];
  const sink = (workspaceId: string, ev: { type: string }) => {
    events.push({ ...(ev as object), workspaceId } as { type: string; workspaceId?: string });
  };
  const oauthStore = new OAuthStore(dataDir);
  const relay = new Relay();
  const dispatcher = new Dispatcher();
  const registry = new AgentRegistry(dataDir, sink as any, oauthStore);
  registerMethods(dispatcher, registry, dataDir, relay, oauthStore, sink, tracker);
  return { dispatcher, registry, events };
}

async function rpc(
  dispatcher: Dispatcher,
  method: string,
  params: Record<string, unknown>,
): Promise<{ result?: unknown; error?: { code: string; message: string } }> {
  const reply = await dispatcher.dispatch("test-id", method, params);
  return JSON.parse(reply) as {
    result?: unknown;
    error?: { code: string; message: string };
  };
}

const cfg = {
  kind: "openai-compatible" as const,
  modelId: "x",
  baseUrl: "http://127.0.0.1:1/v1",
};

describe("qa.run", () => {
  it("rejects when providerConfig is missing", async () => {
    const { dispatcher } = makeStack();
    const r = await rpc(dispatcher, "qa.run", {
      workspaceId: "ws-x",
      firstMessage: "review",
    });
    expect(r.error?.message).toMatch(/providerConfig/);
  });

  it("rejects when firstMessage is missing", async () => {
    const { dispatcher } = makeStack();
    const r = await rpc(dispatcher, "qa.run", {
      workspaceId: "ws-x",
      providerConfig: cfg,
    });
    expect(r.error?.message).toMatch(/firstMessage/);
  });

  it("rejects when workspaceId has no primary session", async () => {
    const { dispatcher } = makeStack();
    const r = await rpc(dispatcher, "qa.run", {
      workspaceId: "ws-missing",
      firstMessage: "review",
      providerConfig: cfg,
    });
    expect(r.error?.message).toMatch(/no primary session/);
  });

  it("returns ok:true and kicks off the QA pass when a primary session exists", async () => {
    const { dispatcher, registry, events } = makeStack();
    await registry.create({
      workspaceId: "ws-1",
      projectId: "p1",
      worktreePath: worktree,
      buildMode: "primary",
      providerConfig: cfg,
    });
    const r = await rpc(dispatcher, "qa.run", {
      workspaceId: "ws-1",
      firstMessage: "review my work",
      providerConfig: cfg,
    });
    expect(r.result).toMatchObject({ ok: true });
    // Give the fire-and-forget QA runner enough time to construct the
    // session and emit agent_start (which happens synchronously after
    // Agent.prompt() before pi-ai's network attempt).
    await new Promise((res) => setTimeout(res, 50));
    const start = events.find(
      (e) => e.type === "agent_start" && e.workspaceId === "ws-1",
    );
    expect(start).toBeDefined();
    // The QA-mode injection in AgentSession.handle() puts kind:"qa"
    // on the wire frame. methods.ts is the integration point that
    // proves the end-to-end wiring works.
    expect((start as { kind?: string }).kind).toBe("qa");
    await registry.disposeAll();
  });
});

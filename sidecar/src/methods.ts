import type { Dispatcher } from "./dispatcher.js";
import type { AgentRegistry } from "./agentRegistry.js";
import type { ProviderConfig } from "./providers.js";

const VERSION = "0.1.0";

export function registerMethods(d: Dispatcher, registry: AgentRegistry): void {
  d.register("health.ping", () => ({ pong: true, version: VERSION }));

  d.register("agent.create", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const worktreePath = requireString(p, "worktreePath");
    const systemPrompt = requireString(p, "systemPrompt");
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    await registry.create({ workspaceId, worktreePath, systemPrompt, providerConfig });
    return { ok: true };
  });

  d.register("agent.prompt", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const message = requireString(p, "message");
    // Don't await Agent.prompt — let it run; events stream over the WebSocket.
    // Errors surface via the event stream as message_end with stopReason "error".
    void registry.get(workspaceId).prompt(message);
    return { ok: true };
  });

  d.register("agent.continue", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    void registry.get(workspaceId).continueRun();
    return { ok: true };
  });

  d.register("agent.abort", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    registry.get(workspaceId).abort();
    return { ok: true };
  });

  d.register("agent.dispose", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    await registry.dispose(workspaceId);
    return { ok: true };
  });

  d.register("agent.list", () => ({ workspaceIds: registry.list() }));
}

function requireString(p: Record<string, unknown>, name: string): string {
  const v = p[name];
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return v;
}

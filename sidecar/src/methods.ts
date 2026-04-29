import type { Dispatcher } from "./dispatcher.js";
import type { AgentRegistry } from "./agentRegistry.js";
import type { ProviderConfig } from "./providers.js";
import { listModels } from "./providers.js";
import { log } from "./logger.js";
import { DataReader } from "./dataReader.js";
import type { Relay } from "./relay.js";

const VERSION = "0.1.0";

export function registerMethods(
  d: Dispatcher,
  registry: AgentRegistry,
  dataDir: string,
  relay: Relay,
): void {
  const reader = new DataReader(dataDir);
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
    // Don't await — events stream over the WebSocket. Catch all errors so
    // a misbehaving provider/tool can never crash the sidecar; report them
    // through the registry's sink as an `agent_error` event the UI can render.
    registry.get(workspaceId).prompt(message).catch((err) => {
      const reason = err instanceof Error ? err.message : String(err);
      log.error("agent.prompt failed", { workspaceId, err: reason });
      registry.emitError(workspaceId, reason);
    });
    return { ok: true };
  });

  d.register("agent.continue", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    registry.get(workspaceId).continueRun().catch((err) => {
      const reason = err instanceof Error ? err.message : String(err);
      log.error("agent.continue failed", { workspaceId, err: reason });
      registry.emitError(workspaceId, reason);
    });
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

  // Read-only views into the Mac app's persisted state, served to iOS.
  d.register("remote.workspaces", () => ({
    workspaces: reader.listWorkspaces(),
    projects: reader.listProjects(),
    providers: reader.listProviders(),
  }));

  d.register("remote.history", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const turns = await reader.historyTurns(workspaceId);
    return { turns };
  });

  d.register("models.list", async (p) => {
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    const models = await listModels(providerConfig);
    return { models };
  });

  // ── Relayed methods ─────────────────────────────────────────────────────
  // These are forwarded to the registered Mac handler client (which has
  // SQLite, git, NSOpenPanel, etc.) and the Mac's response comes back here.
  for (const m of [
    "workspace.create",
    "project.scan",
    "project.create",
    "models.listForProvider",
  ]) {
    d.register(m, async (params) => {
      return await relay.dispatch(m, params);
    });
  }
}

function requireString(p: Record<string, unknown>, name: string): string {
  const v = p[name];
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return v;
}

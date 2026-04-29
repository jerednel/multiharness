import type { Dispatcher } from "./dispatcher.js";
import type { AgentRegistry } from "./agentRegistry.js";
import type { ProviderConfig } from "./providers.js";
import { listModels } from "./providers.js";
import { resolveConflictHunk } from "./conflictResolver.js";
import { log } from "./logger.js";
import { DataReader } from "./dataReader.js";
import type { Relay } from "./relay.js";
import type { WorkspaceActivityTracker } from "./workspaceActivity.js";
import {
  hasAnthropicCreds,
  hasOpenAICodexCreds,
  startAnthropicLogin,
  startOpenAICodexLogin,
  type OAuthStore,
} from "./oauthStore.js";

const VERSION = "0.1.0";

type EventEmit = (workspaceId: string, ev: { type: string; [k: string]: unknown }) => void;

export function registerMethods(
  d: Dispatcher,
  registry: AgentRegistry,
  dataDir: string,
  relay: Relay,
  oauthStore: OAuthStore,
  sink: EventEmit,
  tracker: WorkspaceActivityTracker,
): void {
  const reader = new DataReader(dataDir);
  d.register("health.ping", () => ({ pong: true, version: VERSION }));

  d.register("agent.create", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const projectId = requireString(p, "projectId");
    const worktreePath = requireString(p, "worktreePath");
    const buildModeRaw = requireString(p, "buildMode");
    if (buildModeRaw !== "primary" && buildModeRaw !== "shadowed") {
      throw new Error(`invalid_build_mode: ${buildModeRaw}`);
    }
    const buildMode = buildModeRaw as "primary" | "shadowed";
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    const projectContext = typeof p.projectContext === "string" ? p.projectContext : "";
    const workspaceContext = typeof p.workspaceContext === "string" ? p.workspaceContext : "";
    const nameSourceRaw = typeof p.nameSource === "string" ? p.nameSource : undefined;
    const nameSource =
      nameSourceRaw === "random" || nameSourceRaw === "named"
        ? (nameSourceRaw as "random" | "named")
        : undefined;
    await registry.create({
      workspaceId,
      projectId,
      worktreePath,
      buildMode,
      providerConfig,
      nameSource,
      projectContext,
      workspaceContext,
    });
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

  d.register("agent.resolveConflictHunk", async (p) => {
    const filePath = requireString(p, "filePath");
    const fileContext = requireString(p, "fileContext");
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    return await resolveConflictHunk({
      providerConfig,
      filePath,
      fileContext,
      oauthStore,
    });
  });

  // Push a context update to any live session. No-op when no session exists.
  d.register("agent.applyWorkspaceContext", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const text = typeof p.contextInstructions === "string" ? p.contextInstructions : "";
    registry.applyWorkspaceContext(workspaceId, text);
    return { ok: true };
  });

  d.register("agent.applyProjectContext", async (p) => {
    const projectId = requireString(p, "projectId");
    const text = typeof p.contextInstructions === "string" ? p.contextInstructions : "";
    registry.applyProjectContext(projectId, text);
    return { ok: true };
  });

  // Read-only views into the Mac app's persisted state, served to iOS.
  d.register("remote.workspaces", () => {
    const workspaces = reader.listWorkspaces().map((w) => ({
      ...w,
      isStreaming: tracker.isStreaming(w.id),
      unseen: tracker.isUnseen(w.id, w.lastViewedAt),
    }));
    return {
      workspaces,
      projects: reader.listProjects(),
      providers: reader.listProviders(),
    };
  });

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

  // ── OAuth ───────────────────────────────────────────────────────────────
  d.register("auth.anthropic.status", async () => ({
    loggedIn: await hasAnthropicCreds(oauthStore),
  }));

  d.register("auth.anthropic.start", async () => {
    try {
      await startAnthropicLogin(oauthStore, (url) => {
        sink("", { type: "anthropic_auth_url", url });
      });
      sink("", { type: "anthropic_auth_complete", ok: true });
      return { ok: true };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("anthropic oauth login failed", { reason });
      sink("", { type: "anthropic_auth_complete", ok: false, error: reason });
      throw e;
    }
  });

  d.register("auth.openai.status", async () => ({
    loggedIn: await hasOpenAICodexCreds(oauthStore),
  }));

  d.register("auth.openai.start", async () => {
    try {
      await startOpenAICodexLogin(oauthStore, (url) => {
        sink("", { type: "openai_auth_url", url });
      });
      sink("", { type: "openai_auth_complete", ok: true });
      return { ok: true };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("openai-codex oauth login failed", { reason });
      sink("", { type: "openai_auth_complete", ok: false, error: reason });
      throw e;
    }
  });

  // ── Relayed methods ─────────────────────────────────────────────────────
  // These are forwarded to the registered Mac handler client (which has
  // SQLite, git, NSOpenPanel, etc.) and the Mac's response comes back here.
  for (const m of [
    "workspace.create",
    "workspace.setContext",
    "project.scan",
    "project.create",
    "project.setContext",
    "models.listForProvider",
    "fs.list",
  ]) {
    d.register(m, async (params) => {
      return await relay.dispatch(m, params);
    });
  }

  // workspace.rename is relayed but also broadcasts a workspace_updated
  // event so iOS clients (which only know about workspaces via the cached
  // remote.workspaces snapshot) can reflect the new name without a refetch.
  d.register("workspace.rename", async (params) => {
    const result = await relay.dispatch("workspace.rename", params);
    if (result && typeof result === "object") {
      const r = result as Record<string, unknown>;
      const wsId = typeof r.workspaceId === "string" ? r.workspaceId : "";
      const name = typeof r.name === "string" ? r.name : "";
      if (wsId && name) {
        sink(wsId, {
          type: "workspace_updated",
          name,
          nameSource:
            typeof r.nameSource === "string" ? r.nameSource : "named",
        } as unknown as Parameters<EventEmit>[1]);
      }
    }
    return result;
  });
}

function requireString(p: Record<string, unknown>, name: string): string {
  const v = p[name];
  if (typeof v !== "string" || v.length === 0) {
    throw new Error(`${name} must be a non-empty string`);
  }
  return v;
}

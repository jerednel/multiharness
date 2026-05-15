import type { Dispatcher } from "./dispatcher.js";
import type { AgentRegistry } from "./agentRegistry.js";
import type { ProviderConfig } from "./providers.js";
import { listModels } from "./providers.js";
import { resolveConflictHunk } from "./conflictResolver.js";
import { log } from "./logger.js";
import { DataReader } from "./dataReader.js";
import type { Relay } from "./relay.js";
import type { WorkspaceActivityTracker } from "./workspaceActivity.js";
import { QaRunner } from "./qaRunner.js";
import {
  hasAnthropicCreds,
  hasOpenAICodexCreds,
  startAnthropicLogin,
  startAnthropicConsoleLogin,
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
  // The QA runner is constructed once per sidecar lifetime — its state is
  // empty (no in-memory map) so it doesn't need to live next to the
  // registry. Reuses the same sink as the registry so its events flow
  // through server.ts's broadcast path identically. The `EventSink` /
  // `EventEmit` types differ by a generic constraint (AgentEvent vs.
  // open shape) but at runtime they're the same function — the cast is
  // the same trick AgentRegistry.emitError uses.
  const qaRunner = new QaRunner(
    dataDir,
    sink as unknown as ConstructorParameters<typeof QaRunner>[1],
    oauthStore,
  );
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
    // Optional orientation fields. Older Mac builds may not send them;
    // AgentSession's prompt builder falls back to a path-only block in
    // that case so the orientation is never simply absent.
    const projectName = typeof p.projectName === "string" ? p.projectName : undefined;
    const branchName = typeof p.branchName === "string" ? p.branchName : undefined;
    const baseBranch = typeof p.baseBranch === "string" ? p.baseBranch : undefined;
    const qaSentinelEnabled =
      typeof p.qaSentinelEnabled === "boolean" ? p.qaSentinelEnabled : undefined;
    await registry.create({
      workspaceId,
      projectId,
      worktreePath,
      buildMode,
      providerConfig,
      nameSource,
      projectContext,
      workspaceContext,
      projectName,
      branchName,
      baseBranch,
      qaSentinelEnabled,
    });
    return { ok: true };
  });

  d.register("agent.prompt", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const message = requireString(p, "message");
    // Optional inline images. Each entry: { data: base64, mimeType: string }.
    // Clients enforce per-image size caps; the sidecar trusts the framed
    // payload size limit on the WebSocket layer to catch absurd totals.
    const images = parseImages(p.images);
    // Don't await — events stream over the WebSocket. Catch all errors so
    // a misbehaving provider/tool can never crash the sidecar; report them
    // through the registry's sink as an `agent_error` event the UI can render.
    registry.get(workspaceId).prompt(message, images).catch((err) => {
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

  // ── QA review ────────────────────────────────────────────────────────────
  // Kicks off a transient secondary agent that reviews the primary
  // agent's work in the same worktree, writing into the same JSONL
  // log. The Mac side resolves `providerConfig` (incl. Keychain
  // lookup) and constructs `firstMessage` (diff + last turns) before
  // calling. Returns immediately; events stream as the QA agent
  // runs. Spec §7.
  d.register("qa.run", async (p) => {
    const workspaceId = requireString(p, "workspaceId");
    const firstMessage = requireString(p, "firstMessage");
    const providerConfig = p.providerConfig as ProviderConfig | undefined;
    if (!providerConfig || typeof providerConfig !== "object") {
      throw new Error("providerConfig must be an object");
    }
    // QA runs in the same worktree as the primary session; we pull
    // every contextual field from the primary so the Mac doesn't
    // need to re-send what the sidecar already has. Reject when
    // there's no primary — `agent.create` should always run first.
    if (!registry.has(workspaceId)) {
      throw new Error(`no primary session for workspace ${workspaceId}`);
    }
    const primary = registry.get(workspaceId);
    // Optional orientation fields — older Mac builds may not send
    // them. The QA session's orientation block falls back to a
    // path-only line in that case.
    const projectName = typeof p.projectName === "string" ? p.projectName : undefined;
    const branchName = typeof p.branchName === "string" ? p.branchName : undefined;
    const baseBranch = typeof p.baseBranch === "string" ? p.baseBranch : undefined;
    // Fire-and-forget; errors surface through the sink as
    // agent_error + agent_end (the same path the primary uses).
    qaRunner
      .run({
        workspaceId,
        projectId: primary.projectId,
        worktreePath: primary.worktreePath,
        providerConfig,
        qaPromptText: firstMessage,
        projectName,
        branchName,
        baseBranch,
      })
      .catch((err) => {
        const reason = err instanceof Error ? err.message : String(err);
        log.error("qa.run failed", { workspaceId, err: reason });
        registry.emitError(workspaceId, reason);
      });
    return { ok: true };
  });

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
      lastAssistantAt: tracker.lastAssistantAt(w.id),
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
    const limit = typeof p.limit === "number" ? p.limit : undefined;
    return await reader.historyTurns(workspaceId, { limit });
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

  d.register("auth.anthropic.console.start", async () => {
    try {
      const { apiKey } = await startAnthropicConsoleLogin((url) => {
        sink("", { type: "anthropic_console_auth_url", url });
      });
      sink("", { type: "anthropic_console_auth_complete", ok: true });
      return { apiKey };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("anthropic console oauth login failed", { reason });
      sink("", { type: "anthropic_console_auth_complete", ok: false, error: reason });
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
    "workspace.quickCreate",
    "workspace.setContext",
    "project.scan",
    "project.create",
    "project.createEmpty",
    "project.setContext",
    "project.listBranches",
    "project.update",
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
        });
      }
    }
    return result;
  });

  // Mark a workspace as viewed. The Mac handler writes last_viewed_at to
  // SQLite. After the relay returns we also push a `workspace.activity`
  // event so other connected clients (iOS, multi-instance) flip their
  // local `unseen` flag immediately.
  d.register("workspace.markViewed", async (params) => {
    const result = await relay.dispatch("workspace.markViewed", params);
    const wsId = typeof params.workspaceId === "string" ? params.workspaceId : "";
    if (wsId) {
      sink(wsId, {
        type: "workspace.activity",
        isStreaming: tracker.isStreaming(wsId),
        lastAssistantAt: tracker.lastAssistantAt(wsId),
      });
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

/** Validate the optional `images` array on agent.prompt. Returns undefined
 *  when absent so the AgentSession can fall through to the no-images
 *  Agent.prompt overload (avoids feeding pi-agent-core an empty array,
 *  which it tolerates but the no-arg form is the documented shape). */
function parseImages(
  raw: unknown,
): import("@mariozechner/pi-ai").ImageContent[] | undefined {
  if (raw === undefined || raw === null) return undefined;
  if (!Array.isArray(raw)) throw new Error("images must be an array");
  if (raw.length === 0) return undefined;
  const out: import("@mariozechner/pi-ai").ImageContent[] = [];
  for (const entry of raw) {
    if (!entry || typeof entry !== "object") {
      throw new Error("each image must be an object");
    }
    const e = entry as Record<string, unknown>;
    const data = e.data;
    const mimeType = e.mimeType;
    if (typeof data !== "string" || data.length === 0) {
      throw new Error("image.data must be a non-empty base64 string");
    }
    if (typeof mimeType !== "string" || !mimeType.startsWith("image/")) {
      throw new Error("image.mimeType must be an image/* string");
    }
    out.push({ type: "image", data, mimeType });
  }
  return out;
}

import { Agent, type AgentEvent, type AgentTool } from "@mariozechner/pi-agent-core";
import type { ImageContent, Message } from "@mariozechner/pi-ai";
import { buildModel, apiKeyFor, type ProviderConfig } from "./providers.js";
import { buildTools } from "./tools/index.js";
import { JsonlWriter } from "./jsonl.js";
import { log } from "./logger.js";
import {
  makeTransformContext,
  type CompactionReport,
} from "./contextCompactor.js";
import { makeSummarizer } from "./contextSummarizer.js";
import { probeOllamaContextWindow } from "./ollamaProbe.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";
import {
  buildSystemPrompt,
  buildQaSystemPrompt,
  type BuildMode,
  type SessionMode,
} from "./prompts.js";
import { generateWorkspaceName } from "./workspaceNamer.js";

export type EventSink = (workspaceId: string, ev: AgentEvent) => void;

export type NameSource = "random" | "named";

export type RequestRename = (workspaceId: string, name: string) => Promise<void>;

export type AgentSessionOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  jsonlPath: string;
  sink: EventSink;
  oauthStore?: OAuthStore;
  nameSource: NameSource;
  requestRename?: RequestRename;
  projectContext?: string;
  workspaceContext?: string;
  /// Human-readable project name (e.g. "multiharness"). Used in the
  /// system prompt orientation block so the model knows what repo it's
  /// in without having to inspect the filesystem. Optional for
  /// backwards-compat with older Mac builds; when missing the prompt
  /// falls back to just the worktree path.
  projectName?: string;
  /// Branch the worktree is checked out to.
  branchName?: string;
  /// Branch the worktree was forked from. Helps the model understand
  /// what "the base" means when the user says things like "diff vs
  /// main".
  baseBranch?: string;
  /// Which kind of session this is. Default is `"build"` (the primary
  /// coding agent). `"qa"` uses the read-only reviewer prompt and
  /// suppresses the project/workspace `<*_instructions>` overlays so
  /// reviewer can't be biased by build-time guidance. See spec §5.
  sessionMode?: SessionMode;
  /// Replace the default `buildTools(...)` tool set. Used by the QA
  /// runner to install a read-only subset plus the terminating
  /// `post_qa_findings` tool. When omitted, falls back to `buildTools`.
  toolsOverride?: AgentTool<any>[];
  /// When true, append the QA-ready sentinel instruction to the build
  /// system prompt. The Mac side decides this from the workspace's
  /// effective QA configuration (enabled + model resolvable) and sends
  /// the flag at `agent.create` time. No-op for `sessionMode === "qa"`.
  qaSentinelEnabled?: boolean;
};

// Type widened to `string` because we persist two synthetic events that
// aren't part of pi-agent-core's `AgentEvent` union: the QA runner's
// `qa_findings` (downstream of post_qa_findings calling its sink) and
// AgentSession's own `context_compacted` (emitted from onCompaction()).
const PERSIST_EVENTS = new Set<string>([
  "agent_start",
  "agent_end",
  "turn_end",
  "message_end",
  // tool_execution_start carries args (incl. the per-call description label).
  // Persist both start and end so history rehydration can recover the same
  // step labels users saw live.
  "tool_execution_start",
  "tool_execution_end",
  // QA runner emits qa_findings as a synthetic event when the agent
  // calls post_qa_findings. Persisted so history rehydration can
  // reconstruct the findings card without re-running the QA agent.
  "qa_findings",
  // Emitted by AgentSession.onCompaction whenever the context-compactor
  // had to elide/summarize/drop messages. Persisted so the Mac/iOS apps
  // can render the compaction marker after reopening a workspace.
  "context_compacted",
]);

export class AgentSession {
  private readonly agent: Agent;
  private readonly writer: JsonlWriter;
  private readonly unsubscribe: () => void;
  private seq = 0;
  private projectContext: string;
  private workspaceContext: string;
  private qaSentinelEnabled: boolean;
  /// True iff this workspace's display name is still the random
  /// adjective-noun placeholder. Flipped to false before kicking off the
  /// AI rename so a fast second prompt can't double-fire.
  private aiRenameEligible: boolean;
  /// Last `usage.input` count observed from an assistant message_end.
  /// Used as the anchor for incremental token estimation in the
  /// compactor — much more accurate than chars/4 over the whole
  /// transcript.
  private lastInputTokens: number | undefined;
  /// Snapshot of the transcript at the time `lastInputTokens` was
  /// observed. Compared against the live transcript to compute a delta
  /// estimate for messages appended since.
  private lastInputMessages: Message[] | undefined;
  /// Compacted contextWindow taken from the provider config at
  /// construction. Reading from `this.agent.state.model.contextWindow`
  /// would also work, but caching here keeps the transformContext path
  /// dependency-free and lets tests inject a custom budget.
  ///
  /// Not `readonly` because the Ollama auto-probe (fired-and-forgotten
  /// at construction time) may update it asynchronously when the user
  /// is pointed at an Ollama endpoint whose effective window differs
  /// from whatever was configured.
  private contextWindow: number;

  readonly workspaceId: string;
  readonly projectId: string;

  /// Public so `qa.run` can grab the same path the primary session
  /// is rooted at without forcing the Mac to send it twice. Spec §7.
  get worktreePath(): string {
    return this.opts.worktreePath;
  }

  /// Public for the same reason as `worktreePath` — the QA runner reads
  /// the primary's session mode to assert it's wiring up against an
  /// actual build session, not (somehow) a stray QA one.
  get sessionMode(): SessionMode {
    return this.opts.sessionMode ?? "build";
  }

  constructor(private readonly opts: AgentSessionOptions) {
    this.workspaceId = opts.workspaceId;
    this.projectId = opts.projectId;
    this.projectContext = opts.projectContext ?? "";
    this.workspaceContext = opts.workspaceContext ?? "";
    this.qaSentinelEnabled = opts.qaSentinelEnabled ?? false;
    // QA sessions are never AI-renamed (the spec passes nameSource:"named"
    // explicitly, but also guard at the agent level so a future caller
    // can't accidentally fire renames during a review pass).
    this.aiRenameEligible =
      opts.nameSource === "random" && (opts.sessionMode ?? "build") === "build";
    const cfg = opts.providerConfig;
    const staticKey = apiKeyFor(cfg);
    const model = buildModel(cfg);
    // Surface a usable context-window number for the compactor. Manual
    // configs (Ollama, LM Studio, custom Anthropic proxies) carry it on
    // the provider config; pi-known models carry it on the Model. Fall
    // back to a conservative 128k.
    this.contextWindow =
      (cfg as any).contextWindow
      ?? (model as any).contextWindow
      ?? 128_000;
    this.agent = new Agent({
      initialState: {
        systemPrompt: this.composeSystemPrompt(),
        model: model as any,
        tools: opts.toolsOverride ?? buildTools(opts.worktreePath),
      },
      // Pre-flight context compaction. pi-agent-core calls this before
      // every LLM request with the current transcript; we elide / drop
      // oldest content as needed to keep us under contextWindow. Without
      // this, Ollama-style small-window models OOM-on-context within a
      // handful of tool-heavy turns.
      //
      // Tier 2.5 summarization uses the same provider/model as the main
      // agent — no separate config to manage, and on hosted providers
      // it's typically a sub-cent operation. On Ollama it just makes
      // another local call.
      transformContext: makeTransformContext(
        () => ({
          contextWindow: this.contextWindow,
          lastKnownInputTokens: this.lastInputTokens,
          lastKnownMessages: this.lastInputMessages,
        }),
        (report) => this.onCompaction(report),
        makeSummarizer({
          providerConfig: cfg,
          oauthStore: opts.oauthStore,
          workspaceId: opts.workspaceId,
        }),
      ),
      // OAuth providers (Anthropic Pro/Max) need a fresh access token each
      // request — getApiKey is called by pi-ai right before every API
      // call, so refresh-on-demand happens here.
      getApiKey: async () => {
        if (cfg.kind === "anthropic-oauth") {
          if (!opts.oauthStore) {
            throw new Error("anthropic-oauth requires oauthStore");
          }
          return await getAnthropicAccessToken(opts.oauthStore);
        }
        if (cfg.kind === "openai-codex-oauth") {
          if (!opts.oauthStore) {
            throw new Error("openai-codex-oauth requires oauthStore");
          }
          return await getOpenAICodexAccessToken(opts.oauthStore);
        }
        return staticKey;
      },
    });
    this.writer = new JsonlWriter(opts.jsonlPath);
    this.unsubscribe = this.agent.subscribe((event) => this.handle(event));

    // Ollama / OpenAI-compatible auto-probe. Only runs when the user is
    // on an openai-compatible endpoint AND didn't explicitly configure
    // a contextWindow on the provider config — if they set one we
    // respect it as an authoritative override.
    //
    // Fire-and-forget on purpose: the compactor reads `this.contextWindow`
    // through a closure on every call, so a late update is fine. The
    // first few requests run at the configured (or 128k default) budget;
    // once the probe resolves, subsequent compactions use the real
    // number. We don't block construction because Ollama is sometimes
    // unreachable (LAN endpoint going through Tailscale etc.) and we
    // don't want session-create to wait on it.
    if (cfg.kind === "openai-compatible" && cfg.contextWindow === undefined) {
      void this.probeContextWindow(cfg.baseUrl, cfg.modelId);
    }
  }

  private async probeContextWindow(baseUrl: string, modelId: string): Promise<void> {
    try {
      const r = await probeOllamaContextWindow(baseUrl, modelId);
      if (r.contextWindow && r.contextWindow !== this.contextWindow) {
        log.info("ollama context window auto-detected", {
          workspaceId: this.opts.workspaceId,
          baseUrl,
          modelId,
          numCtx: r.numCtx,
          architectureMax: r.architectureMax,
          previous: this.contextWindow,
          updated: r.contextWindow,
        });
        this.contextWindow = r.contextWindow;
      }
    } catch (e) {
      // probe is internally swallowing errors already; if it throws
      // anyway, nothing we can do but log.
      log.warn("ollama probe threw unexpectedly", {
        workspaceId: this.opts.workspaceId,
        err: e instanceof Error ? e.message : String(e),
      });
    }
  }

  async prompt(message: string, images?: ImageContent[]): Promise<void> {
    if (this.aiRenameEligible) {
      // Flip eligibility before launching the async naming task so a quick
      // second prompt can't double-fire it. The first-prompt text alone is
      // used to seed the workspace name — images aren't fed to the namer.
      this.aiRenameEligible = false;
      void this.generateAndApplyName(message);
    }
    if (images && images.length > 0) {
      await this.agent.prompt(message, images);
    } else {
      await this.agent.prompt(message);
    }
  }

  private async generateAndApplyName(firstMessage: string): Promise<void> {
    if (!this.opts.requestRename) return;
    try {
      const name = await generateWorkspaceName({
        providerConfig: this.opts.providerConfig,
        message: firstMessage,
        oauthStore: this.opts.oauthStore,
      });
      if (!name) {
        log.warn("ai workspace rename produced no usable title", {
          workspaceId: this.opts.workspaceId,
        });
        return;
      }
      await this.opts.requestRename(this.opts.workspaceId, name);
      log.info("ai workspace renamed", {
        workspaceId: this.opts.workspaceId,
        name,
      });
    } catch (e) {
      log.warn("ai workspace rename failed", {
        workspaceId: this.opts.workspaceId,
        err: e instanceof Error ? e.message : String(e),
      });
    }
  }

  async continueRun(): Promise<void> {
    await this.agent.continue();
  }

  abort(): void {
    this.agent.abort();
  }

  setWorkspaceContext(text: string): void {
    this.workspaceContext = text;
    this.agent.state.systemPrompt = this.composeSystemPrompt();
  }

  setProjectContext(text: string): void {
    this.projectContext = text;
    this.agent.state.systemPrompt = this.composeSystemPrompt();
  }

  setQaSentinelEnabled(enabled: boolean): void {
    if (this.qaSentinelEnabled === enabled) return;
    this.qaSentinelEnabled = enabled;
    this.agent.state.systemPrompt = this.composeSystemPrompt();
  }

  /** Exposed for testing. */
  currentSystemPrompt(): string {
    return this.agent.state.systemPrompt;
  }

  private composeSystemPrompt(): string {
    const parts: string[] = [];
    // Anthropic's edge gates the Claude Code rate-limit tier on the
    // exact identity string below appearing in the system prompt.
    // Without it, Console-minted sk-ant-api03 keys get the org's
    // plain-API tier (which on most accounts 429s the first prompt).
    // Prepending it for consoleMint providers keeps us in the high
    // tier — the actual workspace prompt follows immediately after.
    if (
      this.opts.providerConfig.kind === "pi-known" &&
      this.opts.providerConfig.consoleMint
    ) {
      parts.push("You are Claude Code, Anthropic's official CLI for Claude.");
    }
    const mode: SessionMode = this.opts.sessionMode ?? "build";
    if (mode === "qa") {
      // QA reviewer: distinct prompt; deliberately omits the
      // <project_instructions> / <workspace_instructions> blocks (spec
      // §5) so the reviewer isn't biased by the build-time guidance
      // the primary agent was given.
      parts.push(buildQaSystemPrompt());
      parts.push(this.buildOrientation());
    } else {
      parts.push(buildSystemPrompt(this.opts.buildMode, {
        qaSentinelEnabled: this.qaSentinelEnabled,
      }));
      parts.push(this.buildOrientation());
      if (this.projectContext.trim()) {
        parts.push(
          `<project_instructions>\n${this.projectContext}\n</project_instructions>`,
        );
      }
      if (this.workspaceContext.trim()) {
        parts.push(
          `<workspace_instructions>\n${this.workspaceContext}\n</workspace_instructions>`,
        );
      }
    }
    return parts.join("\n\n");
  }

  /// Concrete "you are here" block. Without this the model sees only
  /// "operating inside a git worktree" and treats the worktree path as
  /// an abstraction — when the user says "fix this" it asks "which
  /// project / directory?" even though every filesystem tool is
  /// already scoped to the correct checkout. Naming the project +
  /// branch explicitly anchors the model so it dives into tools
  /// instead of asking for orientation.
  private buildOrientation(): string {
    const projectName = this.opts.projectName?.trim();
    const branch = this.opts.branchName?.trim();
    const base = this.opts.baseBranch?.trim();
    const worktree = this.opts.worktreePath;

    const lines: string[] = ["<workspace_orientation>"];
    if (projectName) {
      lines.push(`Project: ${projectName}`);
    }
    lines.push(`Working directory: ${worktree}`);
    if (branch) {
      const suffix = base ? ` (forked from \`${base}\`)` : "";
      lines.push(`Branch: \`${branch}\`${suffix}`);
    }
    lines.push(
      "All file-system tools (read_file, write_file, edit_file, list_dir, "
        + "glob, grep, bash) are scoped to the working directory above. "
        + "When the user asks you to look at, change, or run something, "
        + "assume they mean THIS checkout unless they explicitly point "
        + "elsewhere. Do not ask the user to confirm the project, repo, "
        + "or directory — use the tools to inspect what's here.",
    );
    lines.push("</workspace_orientation>");
    return lines.join("\n");
  }

  async dispose(): Promise<void> {
    try {
      this.agent.abort();
    } catch {
      // ignore
    }
    this.unsubscribe();
    await this.writer.close();
  }

  private handle(event: AgentEvent): void {
    const mode: SessionMode = this.opts.sessionMode ?? "build";
    // Inject `kind: "qa"` on `agent_start` so the Mac UI can theme this
    // run's transcript group as a QA review (different header, different
    // pill colour). We deliberately don't tag `agent_end` — the Mac
    // attaches the kind to the group at start time and carries it for
    // the run's duration. Spec §7.
    let outgoing: { type: string } = event;
    if (mode === "qa" && event.type === "agent_start") {
      outgoing = { ...(event as object), type: event.type, kind: "qa" } as {
        type: string;
      };
    }
    // The sink signature is typed as AgentEvent; the `kind` field is an
    // extra property that flows through the server's spread-and-broadcast
    // path (see server.ts's `sink`).
    this.opts.sink(
      this.opts.workspaceId,
      outgoing as unknown as AgentEvent,
    );
    // After every completed assistant message we get a fresh, real
    // `usage.input` from the provider. Capture it (plus the transcript
    // snapshot that produced it) so the next compaction can anchor its
    // token estimate against the provider's tokenizer instead of
    // estimating the whole thing from chars/4.
    if (event.type === "message_end") {
      const msg = (event as any).message;
      if (
        msg &&
        msg.role === "assistant" &&
        msg.usage &&
        typeof msg.usage.input === "number"
      ) {
        this.lastInputTokens = msg.usage.input;
        // The state.messages array at this point includes the just-
        // -completed assistant message. The next LLM call's input will
        // be (everything up to and including this assistant message) +
        // any new user/toolResult messages appended afterwards — which
        // is exactly the anchor semantics estimateTokensWithAnchor
        // expects. We slice() to freeze a snapshot; the live state
        // array is mutated in place by the agent loop.
        const snapshot = (this.agent.state.messages as Message[]).slice();
        this.lastInputMessages = snapshot;
      }
    }
    if (PERSIST_EVENTS.has(event.type)) {
      // Persist the (possibly kind-annotated) outgoing event so history
      // rehydration reconstructs the same group structure the live UI
      // saw.
      this.writer
        .append({ seq: this.seq++, ts: Date.now(), event: outgoing as AgentEvent })
        .catch((err) => log.warn("jsonl append failed", { err: String(err) }));
    }
  }

  /// Called by the compactor whenever it had to elide or drop messages.
  /// We log it (visible in the sidecar's structured log for forensics)
  /// and push a `context_compacted` event through the sink so clients
  /// can render a "context was compacted" affordance. The Mac/iOS apps
  /// can ignore unknown event types safely; this gives us a forward-
  /// compatible hook for surfacing compaction in the UI later.
  private onCompaction(report: CompactionReport): void {
    log.info("context compacted", {
      workspaceId: this.opts.workspaceId,
      tier: report.tier,
      beforeTokens: report.beforeTokens,
      afterTokens: report.afterTokens,
      beforeMessages: report.beforeMessages,
      afterMessages: report.afterMessages,
      elidedToolResults: report.elidedToolResults,
      elidedAssistantBlocks: report.elidedAssistantBlocks,
      droppedMessages: report.droppedMessages,
      budget: report.budget,
    });
    this.opts.sink(this.opts.workspaceId, {
      type: "context_compacted",
      ...report,
    } as unknown as AgentEvent);
  }
}

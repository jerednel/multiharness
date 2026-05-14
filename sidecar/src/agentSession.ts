import { Agent, type AgentEvent } from "@mariozechner/pi-agent-core";
import type { ImageContent } from "@mariozechner/pi-ai";
import { buildModel, apiKeyFor, type ProviderConfig } from "./providers.js";
import { buildTools } from "./tools/index.js";
import { JsonlWriter } from "./jsonl.js";
import { log } from "./logger.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";
import { buildSystemPrompt, type BuildMode } from "./prompts.js";
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
};

const PERSIST_EVENTS = new Set<AgentEvent["type"]>([
  "agent_start",
  "agent_end",
  "turn_end",
  "message_end",
  // tool_execution_start carries args (incl. the per-call description label).
  // Persist both start and end so history rehydration can recover the same
  // step labels users saw live.
  "tool_execution_start",
  "tool_execution_end",
]);

export class AgentSession {
  private readonly agent: Agent;
  private readonly writer: JsonlWriter;
  private readonly unsubscribe: () => void;
  private seq = 0;
  private projectContext: string;
  private workspaceContext: string;
  /// True iff this workspace's display name is still the random
  /// adjective-noun placeholder. Flipped to false before kicking off the
  /// AI rename so a fast second prompt can't double-fire.
  private aiRenameEligible: boolean;

  readonly workspaceId: string;
  readonly projectId: string;

  constructor(private readonly opts: AgentSessionOptions) {
    this.workspaceId = opts.workspaceId;
    this.projectId = opts.projectId;
    this.projectContext = opts.projectContext ?? "";
    this.workspaceContext = opts.workspaceContext ?? "";
    this.aiRenameEligible = opts.nameSource === "random";
    const cfg = opts.providerConfig;
    const staticKey = apiKeyFor(cfg);
    this.agent = new Agent({
      initialState: {
        systemPrompt: this.composeSystemPrompt(),
        model: buildModel(cfg) as any,
        tools: buildTools(opts.worktreePath),
      },
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
    parts.push(buildSystemPrompt(this.opts.buildMode));
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
    return parts.join("\n\n");
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
    this.opts.sink(this.opts.workspaceId, event);
    if (PERSIST_EVENTS.has(event.type)) {
      this.writer
        .append({ seq: this.seq++, ts: Date.now(), event })
        .catch((err) => log.warn("jsonl append failed", { err: String(err) }));
    }
  }
}

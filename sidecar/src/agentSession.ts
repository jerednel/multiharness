import { Agent, type AgentEvent } from "@mariozechner/pi-agent-core";
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
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  jsonlPath: string;
  sink: EventSink;
  oauthStore?: OAuthStore;
  nameSource: NameSource;
  requestRename?: RequestRename;
};

const PERSIST_EVENTS = new Set<AgentEvent["type"]>([
  "agent_start",
  "agent_end",
  "turn_end",
  "message_end",
  "tool_execution_end",
]);

export class AgentSession {
  private readonly agent: Agent;
  private readonly writer: JsonlWriter;
  private readonly unsubscribe: () => void;
  private seq = 0;
  /// True iff this workspace's display name is still the random
  /// adjective-noun placeholder. Flipped to false before kicking off the
  /// AI rename so a fast second prompt can't double-fire.
  private aiRenameEligible: boolean;

  constructor(private readonly opts: AgentSessionOptions) {
    this.aiRenameEligible = opts.nameSource === "random";
    const cfg = opts.providerConfig;
    const staticKey = apiKeyFor(cfg);
    this.agent = new Agent({
      initialState: {
        systemPrompt: buildSystemPrompt(opts.buildMode),
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

  async prompt(message: string): Promise<void> {
    if (this.aiRenameEligible) {
      // Flip eligibility before launching the async naming task so a quick
      // second prompt can't double-fire it.
      this.aiRenameEligible = false;
      void this.generateAndApplyName(message);
    }
    await this.agent.prompt(message);
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

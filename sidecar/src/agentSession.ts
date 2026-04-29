import { Agent, type AgentEvent } from "@mariozechner/pi-agent-core";
import { buildModel, apiKeyFor, type ProviderConfig } from "./providers.js";
import { buildTools } from "./tools/index.js";
import { JsonlWriter } from "./jsonl.js";
import { log } from "./logger.js";
import { getAnthropicAccessToken, type OAuthStore } from "./oauthStore.js";

export type EventSink = (workspaceId: string, ev: AgentEvent) => void;

export type AgentSessionOptions = {
  workspaceId: string;
  worktreePath: string;
  systemPrompt: string;
  providerConfig: ProviderConfig;
  jsonlPath: string;
  sink: EventSink;
  oauthStore?: OAuthStore;
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

  constructor(private readonly opts: AgentSessionOptions) {
    const cfg = opts.providerConfig;
    const staticKey = apiKeyFor(cfg);
    this.agent = new Agent({
      initialState: {
        systemPrompt: opts.systemPrompt,
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
        return staticKey;
      },
    });
    this.writer = new JsonlWriter(opts.jsonlPath);
    this.unsubscribe = this.agent.subscribe((event) => this.handle(event));
  }

  async prompt(message: string): Promise<void> {
    await this.agent.prompt(message);
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

import { join } from "node:path";
import { AgentSession, type EventSink } from "./agentSession.js";
import type { ProviderConfig } from "./providers.js";
import type { OAuthStore } from "./oauthStore.js";
import type { BuildMode } from "./prompts.js";

export type CreateOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  projectContext?: string;
  workspaceContext?: string;
};

export class AgentRegistry {
  private readonly sessions = new Map<string, AgentSession>();

  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
    private readonly oauthStore?: OAuthStore,
  ) {}

  async create(opts: CreateOptions): Promise<void> {
    if (this.sessions.has(opts.workspaceId)) {
      throw new Error(`session for workspace ${opts.workspaceId} already exists`);
    }
    const jsonlPath = join(
      this.dataDir,
      "workspaces",
      opts.workspaceId,
      "messages.jsonl",
    );
    const session = new AgentSession({
      ...opts,
      jsonlPath,
      sink: this.sink,
      oauthStore: this.oauthStore,
    });
    this.sessions.set(opts.workspaceId, session);
  }

  get(workspaceId: string): AgentSession {
    const s = this.sessions.get(workspaceId);
    if (!s) throw new Error(`no session for workspace ${workspaceId}`);
    return s;
  }

  has(workspaceId: string): boolean {
    return this.sessions.has(workspaceId);
  }

  list(): string[] {
    return [...this.sessions.keys()];
  }

  /** Push a new workspace context to a single session if present. No-op
   *  when no session exists (the next agent.create will pick up the new
   *  value from the persisted DB). */
  applyWorkspaceContext(workspaceId: string, text: string): void {
    this.sessions.get(workspaceId)?.setWorkspaceContext(text);
  }

  /** Push a new project context to every session whose projectId matches. */
  applyProjectContext(projectId: string, text: string): void {
    for (const s of this.sessions.values()) {
      if (s.projectId === projectId) {
        s.setProjectContext(text);
      }
    }
  }

  async dispose(workspaceId: string): Promise<void> {
    const s = this.sessions.get(workspaceId);
    if (!s) return;
    await s.dispose();
    this.sessions.delete(workspaceId);
  }

  async disposeAll(): Promise<void> {
    for (const id of [...this.sessions.keys()]) await this.dispose(id);
  }

  /** Push a synthetic error event through the sink so the UI can stop showing
   *  "Streaming…" forever when a prompt fails before any agent_end fires. */
  emitError(workspaceId: string, message: string): void {
    this.sink(workspaceId, {
      type: "agent_error",
      message,
    } as unknown as Parameters<EventSink>[1]);
    // Also synthesize agent_end so the UI's isStreaming flag clears.
    this.sink(workspaceId, {
      type: "agent_end",
      messages: [],
    } as unknown as Parameters<EventSink>[1]);
  }
}

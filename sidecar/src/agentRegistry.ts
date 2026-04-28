import { join } from "node:path";
import { AgentSession, type EventSink } from "./agentSession.js";
import type { ProviderConfig } from "./providers.js";

export type CreateOptions = {
  workspaceId: string;
  worktreePath: string;
  systemPrompt: string;
  providerConfig: ProviderConfig;
};

export class AgentRegistry {
  private readonly sessions = new Map<string, AgentSession>();

  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
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
    const session = new AgentSession({ ...opts, jsonlPath, sink: this.sink });
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

  async dispose(workspaceId: string): Promise<void> {
    const s = this.sessions.get(workspaceId);
    if (!s) return;
    await s.dispose();
    this.sessions.delete(workspaceId);
  }

  async disposeAll(): Promise<void> {
    for (const id of [...this.sessions.keys()]) await this.dispose(id);
  }
}

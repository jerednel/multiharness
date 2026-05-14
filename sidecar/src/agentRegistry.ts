import { join } from "node:path";
import { AgentSession, type EventSink, type RequestRename } from "./agentSession.js";
import type { ProviderConfig } from "./providers.js";
import type { OAuthStore } from "./oauthStore.js";
import type { BuildMode } from "./prompts.js";
import type { NameSource } from "./agentSession.js";

export type CreateOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  buildMode: BuildMode;
  providerConfig: ProviderConfig;
  /// Whether the workspace is still wearing its random adjective-noun name
  /// (eligible for AI rename on first prompt) or has a deliberate name.
  /// Defaults to "named" when omitted so callers that don't set it can't
  /// accidentally trigger an AI rename.
  nameSource?: NameSource;
  projectContext?: string;
  workspaceContext?: string;
  /// Human-readable orientation, plumbed through to the AgentSession's
  /// system prompt. All optional for backwards compat — when missing
  /// the orientation block falls back to "Working directory: <path>".
  projectName?: string;
  branchName?: string;
  baseBranch?: string;
};

export class AgentRegistry {
  private readonly sessions = new Map<string, AgentSession>();

  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
    private readonly oauthStore?: OAuthStore,
    private readonly requestRename?: RequestRename,
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
      workspaceId: opts.workspaceId,
      projectId: opts.projectId,
      worktreePath: opts.worktreePath,
      buildMode: opts.buildMode,
      providerConfig: opts.providerConfig,
      jsonlPath,
      sink: this.sink,
      oauthStore: this.oauthStore,
      nameSource: opts.nameSource ?? "named",
      requestRename: this.requestRename,
      projectContext: opts.projectContext,
      workspaceContext: opts.workspaceContext,
      projectName: opts.projectName,
      branchName: opts.branchName,
      baseBranch: opts.baseBranch,
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

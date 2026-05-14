import { join } from "node:path";
import {
  AgentSession,
  type EventSink,
  type AgentSessionOptions,
} from "./agentSession.js";
import { buildReadOnlyTools } from "./tools/index.js";
import type { QaFindingsPayload } from "./tools/postQaFindings.js";
import type { ProviderConfig } from "./providers.js";
import type { OAuthStore } from "./oauthStore.js";
import type { BuildMode } from "./prompts.js";
import { log } from "./logger.js";

export type QaRunOptions = {
  workspaceId: string;
  projectId: string;
  worktreePath: string;
  /// QA provider config (already resolved by the Mac side, including
  /// any Keychain lookup for static API keys). The runner does NOT
  /// re-resolve credentials.
  providerConfig: ProviderConfig;
  /// Pre-built message containing branch info, the last user/assistant
  /// turns, and a truncated diff vs base. Constructed Mac-side so we
  /// can reuse the existing worktree shell helpers (TCC bookmarks,
  /// etc.) — see spec §9.
  qaPromptText: string;
  /// Build mode is irrelevant for the QA prompt itself (the QA system
  /// prompt is mode-agnostic), but `AgentSession` requires the field.
  /// We always pass "primary" here so the orientation block isn't
  /// hobbled by the shadowed-mode "don't run tests" caveat — the QA
  /// agent benefits from running tests when they're cheap.
  buildMode?: BuildMode;
  /// Optional contexts used only by the orientation block (project +
  /// branch name). The QA prompt path skips the
  /// `<project_instructions>` / `<workspace_instructions>` overlays
  /// regardless (spec §5).
  projectName?: string;
  branchName?: string;
  baseBranch?: string;
};

/// Translate a structured QA findings payload into the wire-level event
/// the sink ships. Exported so the unit test can verify the mapping
/// without constructing an `AgentSession`.
export function makeQaFindingsEvent(
  payload: QaFindingsPayload,
): { type: "qa_findings"; verdict: string; summary: string; findings: unknown[] } {
  return {
    type: "qa_findings",
    verdict: payload.verdict,
    summary: payload.summary,
    findings: payload.findings,
  };
}

/// Owns the lifecycle of a single QA review pass. The runner constructs
/// a transient `AgentSession` aimed at the same JSONL file as the
/// primary session, prompts it once, and disposes when the turn ends.
///
/// `AgentRegistry` deliberately does NOT learn about QA sessions —
/// keeping the registry's `Map<workspaceId, AgentSession>` shape
/// unchanged means every existing call site (agent.prompt, applyContext,
/// dispose…) stays oblivious. See spec §4.
export class QaRunner {
  constructor(
    private readonly dataDir: string,
    private readonly sink: EventSink,
    private readonly oauthStore?: OAuthStore,
  ) {}

  /// Kicks off one QA pass. Resolves when the session has been disposed
  /// (after `agent_end`). The returned promise rejects on
  /// session-construction errors; per-turn agent failures surface as
  /// `agent_error`/`agent_end` events through the sink rather than
  /// throwing here.
  async run(opts: QaRunOptions): Promise<void> {
    const jsonlPath = join(
      this.dataDir,
      "workspaces",
      opts.workspaceId,
      "messages.jsonl",
    );
    // Emit a `qa_findings` synthetic event when the agent calls the
    // post_qa_findings tool. We bridge it through the same sink the
    // AgentSession uses so the server's broadcast + persistence path
    // (server.ts's sink → JsonlWriter via PERSIST_EVENTS) treats it
    // uniformly. The tool's args are spread into the event payload.
    const findingsSink = (payload: QaFindingsPayload): void => {
      this.sink(
        opts.workspaceId,
        makeQaFindingsEvent(payload) as unknown as Parameters<EventSink>[1],
      );
    };

    const tools = buildReadOnlyTools(opts.worktreePath, findingsSink);

    const sessionOpts: AgentSessionOptions = {
      workspaceId: opts.workspaceId,
      projectId: opts.projectId,
      worktreePath: opts.worktreePath,
      buildMode: opts.buildMode ?? "primary",
      providerConfig: opts.providerConfig,
      jsonlPath,
      sink: this.sink,
      // Always "named" so the AI-rename path is skipped (spec §4 —
      // QA isn't a build pass).
      nameSource: "named",
      oauthStore: this.oauthStore,
      projectName: opts.projectName,
      branchName: opts.branchName,
      baseBranch: opts.baseBranch,
      sessionMode: "qa",
      toolsOverride: tools,
    };

    const session = new AgentSession(sessionOpts);
    try {
      await session.prompt(opts.qaPromptText);
    } catch (err) {
      log.error("qa session prompt failed", {
        workspaceId: opts.workspaceId,
        err: err instanceof Error ? err.message : String(err),
      });
      throw err;
    } finally {
      await session.dispose();
    }
  }
}

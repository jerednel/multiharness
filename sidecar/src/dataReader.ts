import { Database } from "bun:sqlite";
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { existsSync } from "node:fs";

/**
 * Read-only access to the Mac app's SQLite + JSONL state, used to serve the
 * iOS companion's `remote.workspaces` / `remote.history` RPCs.
 *
 * The sidecar shares MULTIHARNESS_DATA_DIR with the Mac app, so we can open
 * the same `state.db` file. We never write — all data mutations stay on the
 * Mac side.
 */
export class DataReader {
  private db: Database | null = null;

  constructor(private readonly dataDir: string) {
    const dbPath = join(dataDir, "state.db");
    if (existsSync(dbPath)) {
      this.db = new Database(dbPath, { readonly: true });
    }
  }

  isAvailable(): boolean {
    return this.db != null;
  }

  listProjects(): Array<{
    id: string;
    name: string;
    defaultBaseBranch: string;
    defaultBuildMode: string | null;
    contextInstructions: string;
  }> {
    if (!this.db) return [];
    const rows = this.db
      .query(
        "SELECT id, name, default_base_branch AS defaultBaseBranch, default_build_mode AS defaultBuildMode, context_instructions AS contextInstructions FROM projects ORDER BY created_at ASC;",
      )
      .all() as Array<{
        id: string;
        name: string;
        defaultBaseBranch: string;
        defaultBuildMode: string | null;
        contextInstructions: string;
      }>;
    return rows;
  }

  listProviders(): Array<{ id: string; name: string }> {
    if (!this.db) return [];
    const rows = this.db
      .query("SELECT id, name FROM providers ORDER BY created_at ASC;")
      .all() as Array<{ id: string; name: string }>;
    return rows;
  }

  listWorkspaces(): Array<{
    id: string;
    name: string;
    branchName: string;
    baseBranch: string;
    lifecycleState: string;
    projectId: string;
    contextInstructions: string;
    lastViewedAt: number | null;
  }> {
    if (!this.db) return [];
    const rows = this.db
      .query(`
        SELECT
          id,
          name,
          branch_name AS branchName,
          base_branch AS baseBranch,
          lifecycle_state AS lifecycleState,
          project_id AS projectId,
          context_instructions AS contextInstructions,
          last_viewed_at AS lastViewedAt
        FROM workspaces
        WHERE archived_at IS NULL
        ORDER BY created_at DESC;
      `)
      .all() as Array<{
        id: string;
        name: string;
        branchName: string;
        baseBranch: string;
        lifecycleState: string;
        projectId: string;
        contextInstructions: string;
        lastViewedAt: number | null;
      }>;
    return rows;
  }

  /** Reduce the persisted JSONL into a flat list of turns suitable for the
   *  iOS UI: { role, text, toolName?, toolCallDescription?, groupId? }
   *  per item. groupId tags every turn that came between an agent_start
   *  and agent_end so iOS can collapse one run into a single group.
   *
   *  Bounded so a long chat or a single huge pasted message never blows
   *  past the WebSocket frame ceiling on the iOS side. Returns the most
   *  recent `limit` turns (default 500). Each user/assistant turn's text
   *  is capped at `perTurnTextLimit` bytes (default 64 KiB); tool results
   *  keep their existing 800-char preview. `total` is the full count
   *  before slicing so the UI can say "older messages omitted". */
  async historyTurns(
    workspaceId: string,
    options?: { limit?: number; perTurnTextLimit?: number },
  ): Promise<{
    turns: Array<{
      role: "user" | "assistant" | "tool" | "compaction";
      text: string;
      toolName?: string;
      toolCallDescription?: string;
      groupId?: string;
      images?: Array<{ data: string; mimeType: string }>;
      compaction?: {
        tier: number;
        beforeTokens: number;
        afterTokens: number;
        beforeMessages: number;
        afterMessages: number;
        elidedToolResults: number;
        elidedAssistantBlocks: number;
        summarizedTurnPairs: number;
        droppedMessages: number;
        budget: number;
      };
    }>;
    hasMore: boolean;
    total: number;
  }> {
    const limit = Math.max(1, options?.limit ?? 500);
    const perTurnTextLimit = Math.max(256, options?.perTurnTextLimit ?? 64 * 1024);
    const path = join(this.dataDir, "workspaces", workspaceId, "messages.jsonl");
    if (!existsSync(path)) return { turns: [], hasMore: false, total: 0 };
    const text = await readFile(path, "utf8");
    const all: Array<{
      role: "user" | "assistant" | "tool" | "compaction";
      text: string;
      toolName?: string;
      toolCallDescription?: string;
      groupId?: string;
      images?: Array<{ data: string; mimeType: string }>;
      compaction?: {
        tier: number;
        beforeTokens: number;
        afterTokens: number;
        beforeMessages: number;
        afterMessages: number;
        elidedToolResults: number;
        elidedAssistantBlocks: number;
        summarizedTurnPairs: number;
        droppedMessages: number;
        budget: number;
      };
    }> = [];
    let groupId: string | undefined;
    let groupCounter = 0;
    for (const line of text.split("\n")) {
      if (!line.trim()) continue;
      let obj: any;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      const event = obj?.event;
      if (!event) continue;
      if (event.type === "agent_start") {
        // Synthesize a stable per-run id. Real UUIDs would be nicer but
        // these are only consumed for equality comparison by the iOS
        // grouping helper, so a counter is enough.
        groupCounter += 1;
        groupId = `g${groupCounter}`;
      } else if (event.type === "agent_end") {
        groupId = undefined;
      } else if (event.type === "message_end") {
        const msg = event.message;
        if (!msg) continue;
        const t = extractText(msg.content);
        const imgs = msg.role === "user" ? extractImages(msg.content) : [];
        // Drop empty assistant turns, but preserve user turns that are
        // image-only (text empty, images present) so a pasted screenshot
        // with no caption still rehydrates.
        if (!t && imgs.length === 0) continue;
        const capped = t.length > perTurnTextLimit
          ? t.slice(0, perTurnTextLimit) + "…"
          : t;
        if (msg.role === "user") {
          // Live flow appends user turn ungrouped (before agent_start).
          // Replay sees user message_end inside the group; keep it
          // ungrouped to match.
          const entry: (typeof all)[number] = { role: "user", text: capped };
          if (imgs.length > 0) entry.images = imgs;
          all.push(entry);
        } else if (msg.role === "assistant") {
          all.push({ role: "assistant", text: capped, groupId });
        }
      } else if (event.type === "tool_execution_start") {
        const toolName = event.toolName ?? "tool";
        const toolCallDescription = event.args?.description;
        all.push({
          role: "tool",
          text: "",
          toolName,
          ...(toolCallDescription ? { toolCallDescription } : {}),
          ...(groupId ? { groupId } : {}),
        });
      } else if (event.type === "tool_execution_end") {
        let preview = "";
        const content = event.result?.content;
        if (Array.isArray(content) && content[0]?.text) {
          const t = String(content[0].text);
          preview = t.length > 800 ? t.slice(0, 800) + "…" : t;
        }
        // Attach the result to the most recent tool turn — mirrors the
        // serial-execution assumption the live store makes.
        for (let i = all.length - 1; i >= 0; i--) {
          const turn = all[i];
          if (turn && turn.role === "tool") {
            turn.text = preview;
            break;
          }
        }
      } else if (event.type === "context_compacted") {
        // Synthetic event emitted by AgentSession.onCompaction. The
        // sidecar persists these alongside agent_start/end so iOS's
        // remote.history can rehydrate the in-band compaction marker.
        // Field-by-field copy (rather than spread) so we don't leak
        // unrelated event keys into the wire format.
        all.push({
          role: "compaction",
          text: "",
          compaction: {
            tier: typeof event.tier === "number" ? event.tier : 0,
            beforeTokens: event.beforeTokens ?? 0,
            afterTokens: event.afterTokens ?? 0,
            beforeMessages: event.beforeMessages ?? 0,
            afterMessages: event.afterMessages ?? 0,
            elidedToolResults: event.elidedToolResults ?? 0,
            elidedAssistantBlocks: event.elidedAssistantBlocks ?? 0,
            summarizedTurnPairs: event.summarizedTurnPairs ?? 0,
            droppedMessages: event.droppedMessages ?? 0,
            budget: event.budget ?? 0,
          },
        });
      }
    }
    const total = all.length;
    const turns = total > limit ? all.slice(total - limit) : all;
    return { turns, hasMore: total > turns.length, total };
  }
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((item: any) => (item?.type === "text" ? String(item.text ?? "") : ""))
    .join("");
}

/** Pulls inline image parts out of a user-message content array.
 *  pi-ai stores them as `{ type: "image", data, mimeType }`. We mirror
 *  the same shape on the wire so iOS/Mac history rehydration can render
 *  thumbnails without an extra lookup. */
function extractImages(
  content: unknown,
): Array<{ data: string; mimeType: string }> {
  if (!Array.isArray(content)) return [];
  const out: Array<{ data: string; mimeType: string }> = [];
  for (const item of content as any[]) {
    if (item?.type === "image"
      && typeof item.data === "string"
      && typeof item.mimeType === "string") {
      out.push({ data: item.data, mimeType: item.mimeType });
    }
  }
  return out;
}

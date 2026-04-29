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
    defaultBuildMode: string | null;
    contextInstructions: string;
  }> {
    if (!this.db) return [];
    const rows = this.db
      .query(
        "SELECT id, name, default_build_mode AS defaultBuildMode, context_instructions AS contextInstructions FROM projects ORDER BY created_at ASC;",
      )
      .all() as Array<{
        id: string;
        name: string;
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
          context_instructions AS contextInstructions
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
      }>;
    return rows;
  }

  /** Reduce the persisted JSONL into a flat list of turns suitable for the
   *  iOS UI: { role, text, toolName? } per item.
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
    turns: Array<{ role: "user" | "assistant" | "tool"; text: string; toolName?: string }>;
    hasMore: boolean;
    total: number;
  }> {
    const limit = Math.max(1, options?.limit ?? 500);
    const perTurnTextLimit = Math.max(256, options?.perTurnTextLimit ?? 64 * 1024);
    const path = join(this.dataDir, "workspaces", workspaceId, "messages.jsonl");
    if (!existsSync(path)) return { turns: [], hasMore: false, total: 0 };
    const text = await readFile(path, "utf8");
    const all: Array<{ role: "user" | "assistant" | "tool"; text: string; toolName?: string }> =
      [];
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
      if (event.type === "message_end") {
        const msg = event.message;
        if (!msg) continue;
        const t = extractText(msg.content);
        if (!t) continue;
        const capped = t.length > perTurnTextLimit
          ? t.slice(0, perTurnTextLimit) + "…"
          : t;
        if (msg.role === "user") {
          all.push({ role: "user", text: capped });
        } else if (msg.role === "assistant") {
          all.push({ role: "assistant", text: capped });
        }
      } else if (event.type === "tool_execution_end") {
        const toolName = event.toolName ?? "tool";
        let preview = "";
        const content = event.result?.content;
        if (Array.isArray(content) && content[0]?.text) {
          const t = String(content[0].text);
          preview = t.length > 800 ? t.slice(0, 800) + "…" : t;
        }
        all.push({ role: "tool", text: preview, toolName });
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

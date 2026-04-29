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

  listProjects(): Array<{ id: string; name: string }> {
    if (!this.db) return [];
    const rows = this.db
      .query("SELECT id, name FROM projects ORDER BY created_at ASC;")
      .all() as Array<{ id: string; name: string }>;
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
          project_id AS projectId
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
      }>;
    return rows;
  }

  /** Reduce the persisted JSONL into a flat list of turns suitable for the
   *  iOS UI: { role, text, toolName? } per item. */
  async historyTurns(workspaceId: string): Promise<
    Array<{ role: "user" | "assistant" | "tool"; text: string; toolName?: string }>
  > {
    const path = join(this.dataDir, "workspaces", workspaceId, "messages.jsonl");
    if (!existsSync(path)) return [];
    const text = await readFile(path, "utf8");
    const turns: Array<{ role: "user" | "assistant" | "tool"; text: string; toolName?: string }> =
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
        const text = extractText(msg.content);
        if (msg.role === "user" && text) {
          turns.push({ role: "user", text });
        } else if (msg.role === "assistant" && text) {
          turns.push({ role: "assistant", text });
        }
      } else if (event.type === "tool_execution_end") {
        const toolName = event.toolName ?? "tool";
        let preview = "";
        const content = event.result?.content;
        if (Array.isArray(content) && content[0]?.text) {
          const t = String(content[0].text);
          preview = t.length > 800 ? t.slice(0, 800) + "…" : t;
        }
        turns.push({ role: "tool", text: preview, toolName });
      }
    }
    return turns;
  }
}

function extractText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  return content
    .map((item: any) => (item?.type === "text" ? String(item.text ?? "") : ""))
    .join("");
}

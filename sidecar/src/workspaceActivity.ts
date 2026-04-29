import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

/**
 * Tracks per-workspace streaming state and the last `agent_end` timestamp,
 * used to compute `isStreaming` and `unseen` flags for `remote.workspaces`
 * responses and `workspace.activity` events.
 *
 * `lastAssistantAt` is loaded lazily from messages.jsonl on first request,
 * then kept up-to-date via `observe()` calls driven from the wrapped sink
 * in server.ts. Only the file's `ts` field is read, so we don't need to
 * parse big payloads.
 */
export class WorkspaceActivityTracker {
  private readonly streaming = new Set<string>();
  private readonly lastEnd = new Map<string, number>();
  /// Workspaces whose JSONL we've already scanned. Stops repeated disk
  /// reads for workspaces that have never produced an agent_end.
  private readonly scanned = new Set<string>();

  constructor(private readonly dataDir: string) {}

  observe(workspaceId: string, eventType: string): void {
    if (eventType === "agent_start") {
      this.streaming.add(workspaceId);
    } else if (eventType === "agent_end") {
      this.streaming.delete(workspaceId);
      this.lastEnd.set(workspaceId, Date.now());
      this.scanned.add(workspaceId);
    }
  }

  isStreaming(workspaceId: string): boolean {
    return this.streaming.has(workspaceId);
  }

  /** Returns the latest agent_end timestamp in ms, or null if none. */
  lastAssistantAt(workspaceId: string): number | null {
    if (!this.scanned.has(workspaceId)) {
      const ts = this.scanJsonl(workspaceId);
      if (ts !== null) this.lastEnd.set(workspaceId, ts);
      this.scanned.add(workspaceId);
    }
    return this.lastEnd.get(workspaceId) ?? null;
  }

  /** True iff the latest agent_end > lastViewedAt (or no lastViewedAt and
   *  there has been at least one agent_end). */
  isUnseen(workspaceId: string, lastViewedAt: number | null): boolean {
    const last = this.lastAssistantAt(workspaceId);
    if (last === null) return false;
    if (lastViewedAt === null) return true;
    return last > lastViewedAt;
  }

  private scanJsonl(workspaceId: string): number | null {
    const path = join(this.dataDir, "workspaces", workspaceId, "messages.jsonl");
    if (!existsSync(path)) return null;
    let text: string;
    try {
      text = readFileSync(path, "utf8");
    } catch {
      return null;
    }
    let max = -1;
    for (const line of text.split("\n")) {
      if (!line) continue;
      let obj: any;
      try {
        obj = JSON.parse(line);
      } catch {
        continue;
      }
      if (obj?.event?.type !== "agent_end") continue;
      const ts = typeof obj.ts === "number" ? obj.ts : -1;
      if (ts > max) max = ts;
    }
    return max < 0 ? null : max;
  }
}

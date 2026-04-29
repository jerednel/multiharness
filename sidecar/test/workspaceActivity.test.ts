import { describe, it, expect } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { WorkspaceActivityTracker } from "../src/workspaceActivity.js";

function tempDataDir(): string {
  const d = mkdtempSync(join(tmpdir(), "mh-act-"));
  return d;
}

function writeJsonl(dataDir: string, workspaceId: string, lines: string[]): void {
  const dir = join(dataDir, "workspaces", workspaceId);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, "messages.jsonl"), lines.join("\n") + "\n");
}

describe("WorkspaceActivityTracker", () => {
  it("isStreaming reflects observed start/end", () => {
    const t = new WorkspaceActivityTracker(tempDataDir());
    expect(t.isStreaming("w1")).toBe(false);
    t.observe("w1", "agent_start");
    expect(t.isStreaming("w1")).toBe(true);
    t.observe("w1", "agent_end");
    expect(t.isStreaming("w1")).toBe(false);
  });

  it("lastAssistantAt reads the latest agent_end ts from JSONL", () => {
    const dir = tempDataDir();
    writeJsonl(dir, "w2", [
      JSON.stringify({ seq: 0, ts: 1000, event: { type: "agent_start" } }),
      JSON.stringify({ seq: 1, ts: 2000, event: { type: "agent_end", messages: [] } }),
      JSON.stringify({ seq: 2, ts: 3000, event: { type: "agent_end", messages: [] } }),
    ]);
    const t = new WorkspaceActivityTracker(dir);
    expect(t.lastAssistantAt("w2")).toBe(3000);
  });

  it("observe(agent_end) updates lastAssistantAt to now", () => {
    const t = new WorkspaceActivityTracker(tempDataDir());
    const before = Date.now();
    t.observe("w3", "agent_end");
    const got = t.lastAssistantAt("w3");
    expect(got).not.toBeNull();
    expect(got!).toBeGreaterThanOrEqual(before);
  });

  it("isUnseen is true when lastAssistantAt > lastViewedAt", () => {
    const dir = tempDataDir();
    writeJsonl(dir, "w4", [
      JSON.stringify({ seq: 0, ts: 5000, event: { type: "agent_end", messages: [] } }),
    ]);
    const t = new WorkspaceActivityTracker(dir);
    expect(t.isUnseen("w4", 1000)).toBe(true);
    expect(t.isUnseen("w4", 6000)).toBe(false);
    expect(t.isUnseen("w4", null)).toBe(true);
    expect(t.isUnseen("never-active", 0)).toBe(false);
  });
});

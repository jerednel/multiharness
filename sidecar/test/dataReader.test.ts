import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { DataReader } from "../src/dataReader.js";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "mh-datareader-"));
});

function writeHistory(workspaceId: string, lines: string[]): void {
  const wsDir = join(dir, "workspaces", workspaceId);
  mkdirSync(wsDir, { recursive: true });
  writeFileSync(join(wsDir, "messages.jsonl"), lines.join("\n") + "\n", "utf8");
}

function userTurn(text: string): string {
  return JSON.stringify({
    event: {
      type: "message_end",
      message: { role: "user", content: [{ type: "text", text }] },
    },
  });
}

describe("DataReader.historyTurns", () => {
  it("returns empty payload when no JSONL exists", async () => {
    const r = new DataReader(dir);
    const out = await r.historyTurns("missing");
    expect(out).toEqual({ turns: [], hasMore: false, total: 0 });
  });

  it("caps the per-turn text length to keep frames bounded", async () => {
    const big = "x".repeat(200_000); // 200 KB single message
    writeHistory("ws1", [userTurn(big)]);
    const r = new DataReader(dir);
    const out = await r.historyTurns("ws1", { perTurnTextLimit: 1024 });
    expect(out.total).toBe(1);
    expect(out.turns).toHaveLength(1);
    expect(out.turns[0]!.text.length).toBe(1024 + 1); // +1 for the "…" suffix
    expect(out.turns[0]!.text.endsWith("…")).toBe(true);
  });

  it("returns the most recent N turns and reports hasMore", async () => {
    const lines = Array.from({ length: 25 }, (_, i) => userTurn(`m${i}`));
    writeHistory("ws2", lines);
    const r = new DataReader(dir);
    const out = await r.historyTurns("ws2", { limit: 10 });
    expect(out.total).toBe(25);
    expect(out.hasMore).toBe(true);
    expect(out.turns).toHaveLength(10);
    expect(out.turns[0]!.text).toBe("m15");
    expect(out.turns[9]!.text).toBe("m24");
  });

  it("does not flag hasMore when total fits in the limit", async () => {
    writeHistory("ws3", [userTurn("a"), userTurn("b")]);
    const r = new DataReader(dir);
    const out = await r.historyTurns("ws3", { limit: 10 });
    expect(out.total).toBe(2);
    expect(out.hasMore).toBe(false);
    expect(out.turns).toHaveLength(2);
  });

  it("extracts image attachments from user message_end events", async () => {
    // Mirror exactly the shape pi-agent-core persists when prompt() is
    // called with a string + images: a single user message_end whose
    // content array interleaves text and image parts.
    const userWithImages = JSON.stringify({
      event: {
        type: "message_end",
        message: {
          role: "user",
          content: [
            { type: "text", text: "look at this" },
            { type: "image", data: "AAAA", mimeType: "image/png" },
            { type: "image", data: "BBBB", mimeType: "image/jpeg" },
          ],
        },
      },
    });
    writeHistory("ws-img", [userWithImages]);
    const r = new DataReader(dir);
    const out = await r.historyTurns("ws-img");
    expect(out.turns).toHaveLength(1);
    expect(out.turns[0]!.role).toBe("user");
    expect(out.turns[0]!.text).toBe("look at this");
    expect(out.turns[0]!.images).toEqual([
      { data: "AAAA", mimeType: "image/png" },
      { data: "BBBB", mimeType: "image/jpeg" },
    ]);
  });

  it("preserves an image-only user turn (no caption)", async () => {
    // Without this the pre-images guard ("skip turn when text empty")
    // would have dropped image-only sends entirely.
    const onlyImage = JSON.stringify({
      event: {
        type: "message_end",
        message: {
          role: "user",
          content: [{ type: "image", data: "ZZ", mimeType: "image/png" }],
        },
      },
    });
    writeHistory("ws-img2", [onlyImage]);
    const r = new DataReader(dir);
    const out = await r.historyTurns("ws-img2");
    expect(out.turns).toHaveLength(1);
    expect(out.turns[0]!.role).toBe("user");
    expect(out.turns[0]!.text).toBe("");
    expect(out.turns[0]!.images).toEqual([
      { data: "ZZ", mimeType: "image/png" },
    ]);
  });
});

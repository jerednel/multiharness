import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, readFileSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { JsonlWriter } from "../src/jsonl.js";

let dir: string;
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "mh-jsonl-"));
});

describe("JsonlWriter", () => {
  it("creates the file lazily on first write", async () => {
    const w = new JsonlWriter(join(dir, "msgs.jsonl"));
    expect(existsSync(join(dir, "msgs.jsonl"))).toBe(false);
    await w.append({ seq: 0, kind: "user", content: "hi" });
    await w.close();
    expect(existsSync(join(dir, "msgs.jsonl"))).toBe(true);
  });

  it("appends one JSON object per line", async () => {
    const path = join(dir, "msgs.jsonl");
    const w = new JsonlWriter(path);
    await w.append({ seq: 0, content: "a" });
    await w.append({ seq: 1, content: "b" });
    await w.close();
    const lines = readFileSync(path, "utf8").trim().split("\n");
    expect(lines).toHaveLength(2);
    expect(JSON.parse(lines[0]!)).toEqual({ seq: 0, content: "a" });
    expect(JSON.parse(lines[1]!)).toEqual({ seq: 1, content: "b" });
  });

  it("creates parent directories", async () => {
    const path = join(dir, "a", "b", "c", "msgs.jsonl");
    const w = new JsonlWriter(path);
    await w.append({ x: 1 });
    await w.close();
    expect(existsSync(path)).toBe(true);
  });
});

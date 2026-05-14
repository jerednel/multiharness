import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  grepTool,
  MAX_MATCH_LINE_BYTES,
  MAX_GREP_OUTPUT_BYTES,
} from "../../src/tools/grep.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-gr-")));
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src", "a.ts"), "alpha\nbeta\nalphabet\n");
  writeFileSync(join(root, "src", "b.ts"), "gamma\n");
});

describe("grep", () => {
  it("default mode lists matched file paths", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c1", { pattern: "alpha" });
    const text = (r.content[0] as { text: string }).text;
    expect(text).toBe("src/a.ts");
    expect(r.details.mode).toBe("files_with_matches");
    expect(r.details.totalFiles).toBe(1);
    expect(r.details.totalMatches).toBe(2);
    // details still carries every match for the UI.
    const matches = r.details.matches as { path: string; line: number }[];
    expect(matches.map((m) => `${m.path}:${m.line}`).sort()).toEqual([
      "src/a.ts:1",
      "src/a.ts:3",
    ]);
  });

  it("content mode emits line-level matches with path:line: prefix", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c2", {
      pattern: "alpha",
      output_mode: "content",
    });
    const text = (r.content[0] as { text: string }).text;
    expect(text.split("\n").sort()).toEqual([
      "src/a.ts:1: alpha",
      "src/a.ts:3: alphabet",
    ]);
  });

  it("count mode emits one line per file with its hit count", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c3", {
      pattern: "alpha",
      output_mode: "count",
    });
    const text = (r.content[0] as { text: string }).text;
    expect(text).toBe("src/a.ts: 2");
  });

  it("respects optional path filter", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c4", { pattern: "gamma", path: "src/b.ts" });
    const matches = r.details.matches as { path: string }[];
    expect(matches).toHaveLength(1);
    expect((r.content[0] as { text: string }).text).toBe("src/b.ts");
  });

  it("respects head_limit on file list", async () => {
    // 5 files, all matching "needle"
    for (let i = 0; i < 5; i++) {
      writeFileSync(join(root, `f${i}.txt`), "needle\n");
    }
    const tool = grepTool(root);
    const r = await tool.execute("c5", { pattern: "needle", head_limit: 2 });
    const text = (r.content[0] as { text: string }).text;
    expect(text).toContain("more files omitted");
    // details still has all of them.
    expect(r.details.totalFiles).toBe(5);
  });

  it("truncates individual long match lines in content mode", async () => {
    const long = "x".repeat(MAX_MATCH_LINE_BYTES + 500);
    writeFileSync(join(root, "src", "long.ts"), `prefix-${long}-target`);
    const tool = grepTool(root);
    const r = await tool.execute("c6", {
      pattern: "target",
      output_mode: "content",
    });
    const text = (r.content[0] as { text: string }).text;
    expect(text).toContain("match line truncated");
    const matches = r.details.matches as { text: string }[];
    expect(matches[0]!.text.length).toBeGreaterThan(MAX_MATCH_LINE_BYTES);
  });

  it("safety-net byte cap fires when head_limit is set huge in content mode", async () => {
    const wide = "y".repeat(900); // just under per-line cap
    const lines: string[] = [];
    for (let i = 0; i < 200; i++) lines.push(`needle ${wide}`);
    writeFileSync(join(root, "src", "wide.ts"), lines.join("\n"));
    const tool = grepTool(root);
    const r = await tool.execute("c7", {
      pattern: "needle",
      output_mode: "content",
      head_limit: 10_000,
    });
    const text = (r.content[0] as { text: string }).text;
    expect(Buffer.byteLength(text, "utf8")).toBeLessThan(
      MAX_GREP_OUTPUT_BYTES + 1024,
    );
    expect(text).toContain("[truncated:");
  });
});

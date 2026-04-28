import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { grepTool } from "../../src/tools/grep.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-gr-")));
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src", "a.ts"), "alpha\nbeta\nalphabet\n");
  writeFileSync(join(root, "src", "b.ts"), "gamma\n");
});

describe("grep", () => {
  it("matches a literal substring", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c1", { pattern: "alpha" });
    const matches = r.details.matches as { path: string; line: number; text: string }[];
    expect(matches.map((m) => `${m.path}:${m.line}`).sort()).toEqual([
      "src/a.ts:1",
      "src/a.ts:3",
    ]);
  });

  it("respects optional path filter", async () => {
    const tool = grepTool(root);
    const r = await tool.execute("c2", { pattern: "gamma", path: "src/b.ts" });
    const matches = r.details.matches as { path: string }[];
    expect(matches).toHaveLength(1);
  });
});

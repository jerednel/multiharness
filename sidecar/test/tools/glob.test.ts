import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { globTool } from "../../src/tools/glob.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-gl-")));
  mkdirSync(join(root, "src"));
  writeFileSync(join(root, "src", "a.ts"), "");
  writeFileSync(join(root, "src", "b.ts"), "");
  writeFileSync(join(root, "src", "c.txt"), "");
});

describe("glob", () => {
  it("matches by pattern", async () => {
    const tool = globTool(root);
    const r = await tool.execute("c1", { pattern: "src/*.ts" });
    const matches = r.details.matches as string[];
    expect(matches.sort()).toEqual(["src/a.ts", "src/b.ts"]);
  });

  it("returns relative paths from recursive glob", async () => {
    const tool = globTool(root);
    const r = await tool.execute("c2", { pattern: "**/*.txt" });
    const matches = r.details.matches as string[];
    expect(matches).toEqual(["src/c.txt"]);
  });
});

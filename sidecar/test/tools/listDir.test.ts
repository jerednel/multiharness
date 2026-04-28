import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { listDirTool } from "../../src/tools/listDir.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-ld-")));
  mkdirSync(join(root, "sub"));
  writeFileSync(join(root, "a.txt"), "a");
  writeFileSync(join(root, "sub", "b.txt"), "b");
});

describe("list_dir", () => {
  it("lists entries with kinds", async () => {
    const tool = listDirTool(root);
    const r = await tool.execute("c1", { path: "." });
    const entries = r.details.entries as { name: string; kind: string }[];
    const names = new Set(entries.map((e) => e.name));
    expect(names).toEqual(new Set(["a.txt", "sub"]));
    const kinds = Object.fromEntries(entries.map((e) => [e.name, e.kind]));
    expect(kinds["a.txt"]).toBe("file");
    expect(kinds["sub"]).toBe("dir");
  });
});

import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFileTool } from "../../src/tools/readFile.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-rf-")));
  writeFileSync(join(root, "hello.txt"), "world");
});

describe("read_file", () => {
  it("reads UTF-8 file inside worktree", async () => {
    const tool = readFileTool(root);
    const r = await tool.execute("call-1", { path: "hello.txt" });
    expect(r.details).toMatchObject({ content: "world" });
    expect(r.content[0]).toMatchObject({ type: "text", text: "world" });
  });

  it("rejects path traversal", async () => {
    const tool = readFileTool(root);
    await expect(tool.execute("call-2", { path: "../etc/passwd" })).rejects.toThrow(/outside/);
  });

  it("throws for missing file", async () => {
    const tool = readFileTool(root);
    await expect(tool.execute("call-3", { path: "missing.txt" })).rejects.toThrow();
  });
});

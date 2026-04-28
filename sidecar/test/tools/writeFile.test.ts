import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, readFileSync, existsSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { writeFileTool } from "../../src/tools/writeFile.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-wf-")));
});

describe("write_file", () => {
  it("creates a new file with content", async () => {
    const tool = writeFileTool(root);
    const r = await tool.execute("c1", { path: "new.txt", content: "abc" });
    expect(r.details).toMatchObject({ bytes: 3 });
    expect(readFileSync(join(root, "new.txt"), "utf8")).toBe("abc");
  });

  it("creates parent directories", async () => {
    const tool = writeFileTool(root);
    await tool.execute("c2", { path: "a/b/c.txt", content: "x" });
    expect(existsSync(join(root, "a/b/c.txt"))).toBe(true);
  });

  it("overwrites existing file", async () => {
    const tool = writeFileTool(root);
    await tool.execute("c3", { path: "f.txt", content: "first" });
    await tool.execute("c4", { path: "f.txt", content: "second" });
    expect(readFileSync(join(root, "f.txt"), "utf8")).toBe("second");
  });

  it("rejects escapes", async () => {
    const tool = writeFileTool(root);
    await expect(tool.execute("c5", { path: "../bad", content: "x" })).rejects.toThrow(/outside/);
  });
});

import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, writeFileSync, readFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { editFileTool } from "../../src/tools/editFile.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-ef-")));
});

describe("edit_file", () => {
  it("replaces an exact match", async () => {
    writeFileSync(join(root, "f.txt"), "hello world");
    const tool = editFileTool(root);
    await tool.execute("c1", { path: "f.txt", old_string: "world", new_string: "there" });
    expect(readFileSync(join(root, "f.txt"), "utf8")).toBe("hello there");
  });

  it("rejects when old_string not found", async () => {
    writeFileSync(join(root, "f.txt"), "hello world");
    const tool = editFileTool(root);
    await expect(
      tool.execute("c2", { path: "f.txt", old_string: "xyz", new_string: "there" }),
    ).rejects.toThrow(/not found/);
  });

  it("rejects when old_string appears more than once", async () => {
    writeFileSync(join(root, "f.txt"), "abc abc");
    const tool = editFileTool(root);
    await expect(
      tool.execute("c3", { path: "f.txt", old_string: "abc", new_string: "x" }),
    ).rejects.toThrow(/multiple/);
  });
});

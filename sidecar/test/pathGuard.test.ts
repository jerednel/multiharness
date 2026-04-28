import { describe, it, expect, beforeAll } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { resolveInside } from "../src/pathGuard.js";

let root: string;
beforeAll(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-pg-")));
  mkdirSync(join(root, "sub"));
  writeFileSync(join(root, "ok.txt"), "ok");
  writeFileSync(join(root, "sub", "deep.txt"), "deep");
});

describe("resolveInside", () => {
  it("accepts a relative path inside the worktree", () => {
    expect(resolveInside(root, "ok.txt")).toBe(join(root, "ok.txt"));
  });

  it("accepts a relative path with subdir", () => {
    expect(resolveInside(root, "sub/deep.txt")).toBe(join(root, "sub", "deep.txt"));
  });

  it("rejects path-traversal escape", () => {
    expect(() => resolveInside(root, "../etc/passwd")).toThrow(/outside worktree/);
  });

  it("rejects absolute paths outside worktree", () => {
    expect(() => resolveInside(root, "/etc/passwd")).toThrow(/outside worktree/);
  });

  it("accepts absolute path equal to worktree root", () => {
    expect(resolveInside(root, root)).toBe(root);
  });
});

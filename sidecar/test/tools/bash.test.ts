import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bashTool } from "../../src/tools/bash.js";

let root: string;
beforeEach(() => {
  root = realpathSync(mkdtempSync(join(tmpdir(), "mh-bash-")));
});

describe("bash", () => {
  it("runs a simple command", async () => {
    const tool = bashTool(root);
    const r = await tool.execute("c1", { command: "echo hello" });
    expect(r.details.exitCode).toBe(0);
    expect((r.details.stdout as string).trim()).toBe("hello");
  });

  it("captures non-zero exit codes without throwing", async () => {
    const tool = bashTool(root);
    const r = await tool.execute("c2", { command: "exit 7" });
    expect(r.details.exitCode).toBe(7);
  });

  it("kills on timeout", async () => {
    const tool = bashTool(root);
    const r = await tool.execute("c3", { command: "sleep 10", timeout_ms: 200 });
    expect(r.details.timedOut).toBe(true);
  }, 5_000);
});

import { describe, it, expect, beforeEach } from "bun:test";
import { mkdtempSync, realpathSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { bashTool, MAX_STREAM_BYTES } from "../../src/tools/bash.js";

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

  it("truncates oversized stdout in LLM-visible content but keeps details intact", async () => {
    const tool = bashTool(root);
    // Emit MAX + 5KB of bytes via head -c so we don't depend on yes(1) speed.
    const overshoot = MAX_STREAM_BYTES + 5 * 1024;
    const r = await tool.execute("c4", {
      command: `head -c ${overshoot} /dev/zero | tr '\\0' 'a'`,
      timeout_ms: 10_000,
    });
    const summary = (r.content[0] as { text: string }).text;
    expect(summary).toContain("[truncated:");
    expect(summary.length).toBeLessThan(overshoot);
    // Full stream preserved in details for the UI.
    expect((r.details.stdout as string).length).toBe(overshoot);
  }, 15_000);
});

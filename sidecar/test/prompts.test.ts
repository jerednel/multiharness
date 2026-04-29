import { describe, it, expect } from "bun:test";
import { buildSystemPrompt, type BuildMode } from "../src/prompts.js";

describe("buildSystemPrompt", () => {
  it("returns the base prompt for primary mode", () => {
    const out = buildSystemPrompt("primary");
    expect(out).toContain("helpful coding agent operating inside a git worktree");
    expect(out).not.toContain("Builds and tests for this project are run by the user");
  });

  it("appends the shadowed addendum for shadowed mode", () => {
    const out = buildSystemPrompt("shadowed");
    expect(out).toContain("helpful coding agent operating inside a git worktree");
    expect(out).toContain("Builds and tests for this project are run by the user");
    expect(out).toContain("Do not run build, test, or run commands");
  });

  it("rejects unknown modes", () => {
    // @ts-expect-error invalid input
    expect(() => buildSystemPrompt("bogus")).toThrow();
  });
});

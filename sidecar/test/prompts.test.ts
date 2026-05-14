import { describe, it, expect } from "bun:test";
import { buildSystemPrompt, buildQaSystemPrompt, type BuildMode } from "../src/prompts.js";

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

describe("buildQaSystemPrompt", () => {
  it("identifies the reviewer role", () => {
    const out = buildQaSystemPrompt();
    expect(out).toContain("You are a QA reviewer");
  });

  it("names the post_qa_findings tool as the stop condition", () => {
    const out = buildQaSystemPrompt();
    expect(out).toContain("post_qa_findings");
    expect(out).toMatch(/exactly once/);
  });

  it("specifies the three verdict values", () => {
    const out = buildQaSystemPrompt();
    expect(out).toContain("pass");
    expect(out).toContain("minor_issues");
    expect(out).toContain("blocking_issues");
  });

  it("enforces read-only posture", () => {
    const out = buildQaSystemPrompt();
    expect(out).toMatch(/READ-ONLY/);
    expect(out).toMatch(/Do not edit files/);
  });

  it("does not contain the build-mode base prompt", () => {
    // Reviewer is a distinct role, not a flavor of the builder.
    const out = buildQaSystemPrompt();
    expect(out).not.toContain("helpful coding agent operating inside a git worktree");
  });

  it("returns a stable string across invocations", () => {
    expect(buildQaSystemPrompt()).toBe(buildQaSystemPrompt());
  });
});

import { describe, it, expect } from "bun:test";
import {
  generateWorkspaceName,
  sanitizeName,
  type CompleteFn,
} from "../src/workspaceNamer.js";
import type { ProviderConfig } from "../src/providers.js";

const cfg: ProviderConfig = {
  kind: "openai-compatible",
  modelId: "mock",
  baseUrl: "http://localhost:0/v1",
  apiKey: "sk-mock",
};

function fakeComplete(text: string): CompleteFn {
  return async () => ({
    role: "assistant",
    content: [{ type: "text", text }],
    api: "openai-completions",
    provider: "openai-compatible",
    model: "mock",
    usage: {
      input: 0,
      output: 0,
      cacheRead: 0,
      cacheWrite: 0,
      totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
    },
    stopReason: "stop",
    timestamp: Date.now(),
  } as any);
}

describe("sanitizeName", () => {
  it("returns null for empty input", () => {
    expect(sanitizeName("")).toBeNull();
    expect(sanitizeName("   ")).toBeNull();
  });

  it("strips wrapping quotes and backticks", () => {
    expect(sanitizeName('"Add Dark Mode"')).toBe("Add Dark Mode");
    expect(sanitizeName("`Refactor Auth`")).toBe("Refactor Auth");
    expect(sanitizeName("'Fix Bug'")).toBe("Fix Bug");
  });

  it("collapses whitespace and removes newlines", () => {
    expect(sanitizeName("Add  Dark  Mode")).toBe("Add Dark Mode");
    expect(sanitizeName("Line One\nLine Two")).toBe("Line One Line Two");
  });

  it("drops a trailing period", () => {
    expect(sanitizeName("Add a feature.")).toBe("Add a feature");
  });

  it("hard-caps at 40 characters", () => {
    const out = sanitizeName(
      "This is a very long workspace title that goes way past the cap",
    );
    expect(out).not.toBeNull();
    expect(out!.length).toBeLessThanOrEqual(40);
  });

  it("returns null when truncation produces empty string", () => {
    expect(sanitizeName("\n\n\n")).toBeNull();
  });
});

describe("generateWorkspaceName", () => {
  it("returns the sanitized title when the model produces a clean line", async () => {
    const out = await generateWorkspaceName(
      { providerConfig: cfg, message: "Add dark mode to settings" },
      fakeComplete("Add Dark Mode Toggle"),
    );
    expect(out).toBe("Add Dark Mode Toggle");
  });

  it("returns null when the model produces empty output", async () => {
    const out = await generateWorkspaceName(
      { providerConfig: cfg, message: "Anything" },
      fakeComplete(""),
    );
    expect(out).toBeNull();
  });

  it("returns null when complete throws", async () => {
    const throwing: CompleteFn = async () => {
      throw new Error("provider exploded");
    };
    const out = await generateWorkspaceName(
      { providerConfig: cfg, message: "Anything" },
      throwing,
    );
    expect(out).toBeNull();
  });
});

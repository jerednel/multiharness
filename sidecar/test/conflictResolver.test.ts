import { describe, it, expect } from "bun:test";
import {
  resolveConflictHunk,
  type CompleteFn,
} from "../src/conflictResolver.js";
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
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
    stopReason: "stop",
    timestamp: Date.now(),
  } as any);
}

describe("resolveConflictHunk", () => {
  const fileContext = "line 1\n<<<<<<< HEAD\nfrom a\n=======\nfrom b\n>>>>>>> feature-b\nline 3\n";

  it("returns resolved text when the model produces a clean response", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("line 1\nfrom a and from b\nline 3\n"),
    );
    expect(out.outcome).toBe("resolved");
    if (out.outcome === "resolved") {
      expect(out.content).toContain("from a and from b");
    }
  });

  it("parses __DECLINED__ as a decline with reason", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("__DECLINED__ ambiguous semantic intent"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("ambiguous");
    }
  });

  it("declines responses that still contain conflict markers", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("line 1\n<<<<<<< HEAD\nfrom a\n=======\nfrom b\n>>>>>>> feature-b\nline 3\n"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("markers");
    }
  });

  it("declines responses that are too short", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete("ok"),
    );
    expect(out.outcome).toBe("declined");
    if (out.outcome === "declined") {
      expect(out.reason).toContain("too short");
    }
  });

  it("declines empty responses", async () => {
    const out = await resolveConflictHunk(
      { providerConfig: cfg, filePath: "a.txt", fileContext },
      fakeComplete(""),
    );
    expect(out.outcome).toBe("declined");
  });
});

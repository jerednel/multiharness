import { describe, it, expect } from "bun:test";
import { buildModel, PROVIDER_PRESETS } from "../src/providers.js";

describe("buildModel — pi-known providers", () => {
  it("resolves an OpenRouter model from the registry", () => {
    const m = buildModel({
      kind: "pi-known",
      provider: "openrouter",
      modelId: "openrouter/auto",
      apiKey: "sk-mock",
    });
    expect(m.provider).toContain("openrouter");
    expect(m.baseUrl).toBe("https://openrouter.ai/api/v1");
    expect(m.id).toBe("openrouter/auto");
  });

  it("resolves an OpenCode-Go model from the registry", () => {
    // pick a model that exists in the registry
    const m = buildModel({
      kind: "pi-known",
      provider: "opencode-go",
      modelId: "minimax-m2.5",
      apiKey: "sk-mock",
    });
    expect(m.provider).toBe("opencode-go");
    expect(m.baseUrl).toBe("https://opencode.ai/zen/go/v1");
    expect(m.id).toBe("minimax-m2.5");
  });

  it("throws clearly when the (provider, modelId) is unknown", () => {
    expect(() =>
      buildModel({
        kind: "pi-known",
        provider: "openrouter",
        modelId: "definitely-not-a-real-model-id-12345" as any,
        apiKey: "sk-mock",
      }),
    ).toThrow();
  });
});

describe("buildModel — fully custom endpoints", () => {
  it("constructs an OpenAI-compatible model for LM Studio", () => {
    const m = buildModel({
      kind: "openai-compatible",
      modelId: "qwen2.5-7b-instruct",
      baseUrl: "http://localhost:1234/v1",
    });
    expect(m.api).toBe("openai-completions");
    expect(m.baseUrl).toBe("http://localhost:1234/v1");
  });

  it("constructs an Anthropic model with default base URL", () => {
    const m = buildModel({
      kind: "anthropic",
      modelId: "claude-sonnet-4-6",
      apiKey: "sk-ant-mock",
    });
    expect(m.api).toBe("anthropic-messages");
    expect(m.baseUrl).toBe("https://api.anthropic.com/v1");
  });
});

describe("PROVIDER_PRESETS", () => {
  it("includes LM Studio, OpenRouter, and OpenCode", () => {
    const ids = PROVIDER_PRESETS.map((p) => p.id);
    expect(ids).toContain("lm-studio");
    expect(ids).toContain("openrouter");
    expect(ids).toContain("opencode");
    expect(ids).toContain("opencode-go");
  });
});

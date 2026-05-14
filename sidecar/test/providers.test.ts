import { describe, it, expect } from "bun:test";
import { apiKeyFor, buildModel, listModels, PROVIDER_PRESETS } from "../src/providers.js";

describe("apiKeyFor", () => {
  it("returns the configured key for openai-compatible providers", () => {
    expect(
      apiKeyFor({
        kind: "openai-compatible",
        modelId: "x",
        baseUrl: "http://localhost:1234/v1",
        apiKey: "sk-user",
      }),
    ).toBe("sk-user");
  });

  // Without this fallback, pi-ai's streamSimpleOpenAICompletions throws
  // "No API key for provider: openai-compatible" before ever calling Ollama,
  // LM Studio, vLLM, or llama.cpp — all of which accept any/no auth header.
  it("returns a placeholder for openai-compatible providers with no key", () => {
    const key = apiKeyFor({
      kind: "openai-compatible",
      modelId: "llama3",
      baseUrl: "http://localhost:11434/v1",
    });
    expect(typeof key).toBe("string");
    expect(key && key.length > 0).toBe(true);
  });

  it("returns undefined for OAuth providers (token resolved per-request)", () => {
    expect(apiKeyFor({ kind: "anthropic-oauth", modelId: "x" })).toBeUndefined();
    expect(apiKeyFor({ kind: "openai-codex-oauth", modelId: "x" })).toBeUndefined();
  });
});

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

describe("buildModel — image input declarations", () => {
  // Regression guard: pi-ai's transformMessages strips every image block
  // (replacing it with a placeholder string) when model.input lacks "image".
  // If any of these flip back to text-only, image attachments will be
  // silently dropped before they hit the wire — Anthropic loses vision,
  // Ollama/LM Studio vision models (qwen2.5-vl, qwen3-vl, llava, …) stop
  // receiving pixels, and the bug looks like "the model can't see images"
  // when really we never sent them.
  it("declares image input on the anthropic kind", () => {
    const m = buildModel({
      kind: "anthropic",
      modelId: "claude-sonnet-4-6",
      apiKey: "sk-ant-mock",
    });
    expect(m.input).toContain("image");
  });

  it("declares image input on the openai-compatible kind (Ollama/LM Studio)", () => {
    const m = buildModel({
      kind: "openai-compatible",
      modelId: "qwen3-vl:30b",
      baseUrl: "http://localhost:11434/v1",
    });
    expect(m.input).toContain("image");
    expect(m.input).toContain("text");
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

describe("listModels", () => {
  it("returns registry-backed models for a pi-known provider", async () => {
    const models = await listModels({
      kind: "pi-known",
      provider: "openrouter",
      modelId: "openrouter/auto",
    });
    expect(models.length).toBeGreaterThan(50);
    expect(models[0]?.source).toBe("registry");
  });

  it("hits /models on an OpenAI-compatible base URL", async () => {
    const port = 19500 + Math.floor(Math.random() * 100);
    const server = Bun.serve({
      port,
      fetch(req) {
        if (req.url.endsWith("/models")) {
          return Response.json({
            data: [
              { id: "model-a", display_name: "Model A", context_window: 8192 },
              { id: "model-b" },
            ],
          });
        }
        return new Response("not found", { status: 404 });
      },
    });
    try {
      const models = await listModels({
        kind: "openai-compatible",
        modelId: "ignored",
        baseUrl: `http://127.0.0.1:${port}/v1`,
      });
      expect(models).toHaveLength(2);
      expect(models[0]).toEqual({
        id: "model-a",
        name: "Model A",
        contextWindow: 8192,
        source: "remote",
      });
      expect(models[1]?.id).toBe("model-b");
    } finally {
      server.stop();
    }
  });

  it("surfaces non-2xx as a clear error", async () => {
    const port = 19600 + Math.floor(Math.random() * 100);
    const server = Bun.serve({
      port,
      fetch() {
        return new Response("nope", { status: 500 });
      },
    });
    try {
      await expect(
        listModels({
          kind: "openai-compatible",
          modelId: "x",
          baseUrl: `http://127.0.0.1:${port}/v1`,
        }),
      ).rejects.toThrow(/500/);
    } finally {
      server.stop();
    }
  });
});

import type { Model } from "@mariozechner/pi-ai";

/**
 * Provider config sent over the wire by the Mac app on agent.create.
 *
 * - "anthropic": real Anthropic API or Anthropic-compatible endpoint.
 * - "openai-compatible": OpenAI proper, LM Studio, Ollama, vLLM, OpenRouter,
 *   any other endpoint that speaks the OpenAI Chat Completions protocol.
 */
export type ProviderConfig =
  | {
      kind: "anthropic";
      modelId: string;
      apiKey: string;
      baseUrl?: string;
      contextWindow?: number;
      maxTokens?: number;
    }
  | {
      kind: "openai-compatible";
      modelId: string;
      baseUrl: string;
      apiKey?: string;
      contextWindow?: number;
      maxTokens?: number;
    };

const DEFAULT_CONTEXT_WINDOW = 128_000;
const DEFAULT_MAX_TOKENS = 16_000;

export function buildModel(cfg: ProviderConfig): Model<"openai-completions"> | Model<"anthropic-messages"> {
  if (cfg.kind === "anthropic") {
    const m: Model<"anthropic-messages"> = {
      id: cfg.modelId,
      name: cfg.modelId,
      api: "anthropic-messages",
      provider: "anthropic",
      baseUrl: cfg.baseUrl ?? "https://api.anthropic.com/v1",
      reasoning: false,
      input: ["text", "image"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: cfg.contextWindow ?? 200_000,
      maxTokens: cfg.maxTokens ?? 8_000,
    };
    return m;
  }
  const m: Model<"openai-completions"> = {
    id: cfg.modelId,
    name: cfg.modelId,
    api: "openai-completions",
    provider: "openai-compatible",
    baseUrl: cfg.baseUrl,
    reasoning: false,
    input: ["text"],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: cfg.contextWindow ?? DEFAULT_CONTEXT_WINDOW,
    maxTokens: cfg.maxTokens ?? DEFAULT_MAX_TOKENS,
  };
  return m;
}

export function apiKeyFor(cfg: ProviderConfig): string | undefined {
  return cfg.apiKey;
}

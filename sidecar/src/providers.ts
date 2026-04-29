import { getModel, getModels, type Model, type KnownProvider } from "@mariozechner/pi-ai";

/**
 * Provider config sent over the wire by the Mac app on agent.create.
 *
 * Three flavors:
 *
 * - "pi-known": delegate to pi-ai's curated provider registry. Handles
 *   OpenRouter, OpenAI, Anthropic, OpenCode (Zen + Go), DeepSeek, Mistral,
 *   Groq, Cerebras, xAI, MiniMax, Hugging Face, Fireworks, Cloudflare, etc.
 *   Use this whenever the model is in pi-ai's registry — you get correct
 *   baseUrl, headers, cost metadata, and context-window data automatically.
 *
 * - "openai-compatible": fully manual config for any OpenAI-compatible
 *   endpoint not in pi-ai's registry — LM Studio, Ollama, vLLM, custom
 *   company proxies, or new OpenRouter models that haven't been added to
 *   pi-ai yet.
 *
 * - "anthropic": fully manual config for an Anthropic-compatible endpoint
 *   (real Anthropic, or a self-hosted Claude-API proxy).
 */
export type ProviderConfig =
  | {
      kind: "pi-known";
      provider: KnownProvider;
      modelId: string;
      apiKey?: string;
    }
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

export function buildModel(cfg: ProviderConfig): Model<any> {
  if (cfg.kind === "pi-known") {
    // pi-ai's getModel returns undefined for unknown (provider, modelId)
    // pairs; we surface that as a thrown error so callers see a clear
    // failure rather than passing undefined into the Agent.
    const m = getModel(cfg.provider as any, cfg.modelId as any) as
      | Model<any>
      | undefined;
    if (!m) {
      throw new Error(
        `pi-ai has no model "${cfg.modelId}" registered for provider "${cfg.provider}"`,
      );
    }
    return m;
  }
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

export type DiscoveredModel = {
  id: string;
  name?: string;
  contextWindow?: number;
  source: "registry" | "remote";
};

/**
 * List models available for a provider config.
 *
 * - "pi-known": pulled from pi-ai's curated registry (no network call).
 * - "openai-compatible" / "anthropic": HTTP GET `${baseUrl}/models` with the
 *   provided api key, returns whatever the server enumerates.
 */
export async function listModels(cfg: ProviderConfig): Promise<DiscoveredModel[]> {
  if (cfg.kind === "pi-known") {
    const models = getModels(cfg.provider as any) as Array<Model<any>>;
    return models.map((m) => ({
      id: m.id,
      name: m.name,
      contextWindow: (m as any).contextWindow,
      source: "registry" as const,
    }));
  }

  const baseUrl = cfg.kind === "anthropic"
    ? cfg.baseUrl ?? "https://api.anthropic.com/v1"
    : cfg.baseUrl;
  if (!baseUrl) throw new Error("baseUrl is required");

  // Both OpenAI-compatible and Anthropic expose GET /models. Auth differs:
  // OpenAI uses `Authorization: Bearer <key>`, Anthropic uses `x-api-key: <key>`
  // plus a required `anthropic-version` header.
  const url = baseUrl.replace(/\/+$/, "") + "/models";
  const headers: Record<string, string> = { "accept": "application/json" };
  if (cfg.apiKey) {
    if (cfg.kind === "anthropic") {
      headers["x-api-key"] = cfg.apiKey;
      headers["anthropic-version"] = "2023-06-01";
    } else {
      headers["authorization"] = `Bearer ${cfg.apiKey}`;
    }
  }

  const res = await fetch(url, { headers });
  if (!res.ok) {
    const body = await res.text().catch(() => "");
    throw new Error(`GET ${url} failed: ${res.status} ${body.slice(0, 200)}`);
  }
  const json: any = await res.json();
  const data: any[] = Array.isArray(json) ? json : json?.data ?? json?.models ?? [];
  return data.map((m) => ({
    id: typeof m === "string" ? m : (m.id ?? m.name ?? ""),
    name: typeof m === "string" ? undefined : m.display_name ?? m.name,
    contextWindow: typeof m === "object" ? m.context_window ?? m.context_length : undefined,
    source: "remote" as const,
  })).filter((m) => m.id);
}

/**
 * Built-in provider presets surfaced by the Mac app's "Add provider" UI.
 * The Mac app only needs to know the displayName, the wire-level kind, and
 * (for openai-compatible presets) the baseUrl. Models are picked separately.
 */
export type ProviderPreset = {
  id: string;
  displayName: string;
  kind: ProviderConfig["kind"];
  /** Set on `kind: "pi-known"` presets. */
  piProvider?: KnownProvider;
  /** Set on `kind: "openai-compatible"` and `kind: "anthropic"` presets. */
  baseUrl?: string;
  /** Documentation URL for getting an API key. */
  docsUrl?: string;
  /** True when the preset typically requires no key (local). */
  noKeyRequired?: boolean;
};

export const PROVIDER_PRESETS: ProviderPreset[] = [
  {
    id: "lm-studio",
    displayName: "LM Studio (local)",
    kind: "openai-compatible",
    baseUrl: "http://localhost:1234/v1",
    noKeyRequired: true,
  },
  {
    id: "ollama",
    displayName: "Ollama (local)",
    kind: "openai-compatible",
    baseUrl: "http://localhost:11434/v1",
    noKeyRequired: true,
  },
  {
    id: "openrouter",
    displayName: "OpenRouter",
    kind: "pi-known",
    piProvider: "openrouter",
    docsUrl: "https://openrouter.ai/keys",
  },
  {
    id: "opencode",
    displayName: "OpenCode (Zen)",
    kind: "pi-known",
    piProvider: "opencode",
    docsUrl: "https://opencode.ai",
  },
  {
    id: "opencode-go",
    displayName: "OpenCode Go",
    kind: "pi-known",
    piProvider: "opencode-go",
    docsUrl: "https://opencode.ai",
  },
  {
    id: "openai",
    displayName: "OpenAI",
    kind: "pi-known",
    piProvider: "openai",
    docsUrl: "https://platform.openai.com/api-keys",
  },
  {
    id: "anthropic",
    displayName: "Anthropic",
    kind: "pi-known",
    piProvider: "anthropic",
    docsUrl: "https://console.anthropic.com/settings/keys",
  },
];

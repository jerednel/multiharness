import { complete } from "@mariozechner/pi-ai";
import { buildModel, type ProviderConfig } from "./providers.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";

export type CompleteFn = typeof complete;

const SYSTEM_PROMPT =
  "You name software work-in-progress. Given the user's first instruction, return a 2–6 word title in Title Case, no punctuation, no quotes, no trailing period. Just the title. ≤40 chars.";

const MAX_LEN = 40;

/// Generate a short workspace title from the user's first prompt. Returns
/// `null` on any failure (timeout, model error, empty/garbage output) so
/// callers can silently fall back to the existing random name.
export async function generateWorkspaceName(
  args: {
    providerConfig: ProviderConfig;
    message: string;
    oauthStore?: OAuthStore;
    signal?: AbortSignal;
  },
  completeFn: CompleteFn = complete,
): Promise<string | null> {
  try {
    const apiKey = await resolveApiKey(args.providerConfig, args.oauthStore);
    const model = buildModel(args.providerConfig);
    const timeoutSignal = AbortSignal.timeout(20_000);
    const sig = args.signal
      ? AbortSignal.any([args.signal, timeoutSignal])
      : timeoutSignal;
    const result = await completeFn(
      model as any,
      {
        systemPrompt: SYSTEM_PROMPT,
        messages: [
          {
            role: "user",
            content: [{ type: "text", text: args.message }],
            timestamp: Date.now(),
          },
        ],
      },
      { apiKey, signal: sig, maxTokens: 64 },
    );
    return sanitizeName(extractText(result));
  } catch {
    return null;
  }
}

export function sanitizeName(raw: string): string | null {
  if (!raw) return null;
  let s = raw.replace(/[\r\n]+/g, " ").trim();
  // Strip common wrapping punctuation models like to add.
  s = s.replace(/^[\s"'`*_]+/, "").replace(/[\s"'`*_]+$/, "");
  // Drop trailing period.
  s = s.replace(/\.$/, "");
  // Collapse internal whitespace.
  s = s.replace(/\s+/g, " ").trim();
  if (!s) return null;
  if (s.length > MAX_LEN) {
    s = s.slice(0, MAX_LEN).trim();
  }
  return s.length > 0 ? s : null;
}

async function resolveApiKey(
  cfg: ProviderConfig,
  oauthStore?: OAuthStore,
): Promise<string | undefined> {
  if (cfg.kind === "anthropic-oauth") {
    if (!oauthStore) throw new Error("anthropic-oauth requires oauthStore");
    return await getAnthropicAccessToken(oauthStore);
  }
  if (cfg.kind === "openai-codex-oauth") {
    if (!oauthStore) throw new Error("openai-codex-oauth requires oauthStore");
    return await getOpenAICodexAccessToken(oauthStore);
  }
  return cfg.apiKey;
}

function extractText(msg: { content: unknown[] }): string {
  return msg.content
    .filter((p): p is { type: string; text: string } => {
      return (
        !!p &&
        typeof p === "object" &&
        (p as { type?: string }).type === "text" &&
        typeof (p as { text?: unknown }).text === "string"
      );
    })
    .map((p) => p.text)
    .join("");
}

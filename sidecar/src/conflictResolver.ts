import { complete } from "@mariozechner/pi-ai";
import { buildModel, type ProviderConfig } from "./providers.js";
import {
  getAnthropicAccessToken,
  getOpenAICodexAccessToken,
  type OAuthStore,
} from "./oauthStore.js";

export type ResolveOutcome =
  | { outcome: "resolved"; content: string }
  | { outcome: "declined"; reason: string };

export type CompleteFn = typeof complete;

const SYSTEM_PROMPT =
  "You are resolving a 3-way merge conflict. The user has shown you the full text of one file containing one or more `<<<<<<<` / `=======` / `>>>>>>>` conflict markers. Output the complete file with all conflicts resolved — no commentary, no markdown fences, no explanation. If you cannot resolve a conflict because the two sides express incompatible intent that requires human judgment, instead output the literal token `__DECLINED__` followed by a single short sentence explaining why.";

export async function resolveConflictHunk(
  args: {
    providerConfig: ProviderConfig;
    filePath: string;
    fileContext: string;
    oauthStore?: OAuthStore;
    signal?: AbortSignal;
  },
  completeFn: CompleteFn = complete,
): Promise<ResolveOutcome> {
  const { providerConfig, fileContext, oauthStore, signal } = args;
  const apiKey = await resolveApiKey(providerConfig, oauthStore);
  const model = buildModel(providerConfig);
  const result = await completeFn(
    model as any,
    {
      systemPrompt: SYSTEM_PROMPT,
      messages: [
        { role: "user", content: [{ type: "text", text: fileContext }], timestamp: Date.now() },
      ],
    },
    { apiKey, signal, maxTokens: 8192 },
  );
  const text = extractText(result);
  if (!text) return { outcome: "declined", reason: "model returned no text" };
  if (text.startsWith("__DECLINED__")) {
    const reason =
      text.slice("__DECLINED__".length).trim() || "no reason given";
    return { outcome: "declined", reason };
  }
  // A resolved file should be at least as long as the non-marker content in
  // the conflicted version. Conflict markers add ~30+ chars of overhead, so
  // require the response to be at least 20% of the conflicted text's length
  // but no less than 10 characters — this rejects trivially empty or garbage
  // responses while allowing legitimately compact resolutions.
  const minLength = Math.max(10, Math.floor(fileContext.length * 0.2));
  if (text.length < minLength) {
    return { outcome: "declined", reason: "malformed response (too short)" };
  }
  if (text.includes("<<<<<<<")) {
    return {
      outcome: "declined",
      reason: "malformed response (unresolved markers)",
    };
  }
  return { outcome: "resolved", content: text };
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

function extractText(msg: { content: any[] }): string {
  return msg.content
    .filter((p) => p.type === "text")
    .map((p) => p.text as string)
    .join("");
}

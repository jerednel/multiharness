import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  loginAnthropic,
  refreshAnthropicToken,
  anthropicOAuthProvider,
  loginOpenAICodex,
  refreshOpenAICodexToken,
  openaiCodexOAuthProvider,
  type OAuthCredentials,
} from "@mariozechner/pi-ai/oauth";
import { log } from "./logger.js";
import { loginAnthropicConsole } from "./anthropicConsoleAuth.js";

/**
 * Persisted OAuth credentials for the supported providers. Lives at
 * <dataDir>/oauth/<provider>.json. The Mac app's Keychain wrapper would be
 * stronger, but the sidecar can't reach Keychain directly — and the file
 * is in ~/Library/Application Support/Multiharness which is already
 * user-only.
 */
export class OAuthStore {
  constructor(private readonly dataDir: string) {}

  private filePath(provider: string): string {
    return `${this.dataDir}/oauth/${provider}.json`;
  }

  async load(provider: string): Promise<OAuthCredentials | null> {
    try {
      const text = await readFile(this.filePath(provider), "utf8");
      return JSON.parse(text) as OAuthCredentials;
    } catch {
      return null;
    }
  }

  async save(provider: string, creds: OAuthCredentials): Promise<void> {
    const path = this.filePath(provider);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, JSON.stringify(creds, null, 2), { encoding: "utf8", mode: 0o600 });
  }

  async clear(provider: string): Promise<void> {
    try {
      await writeFile(this.filePath(provider), "{}", "utf8");
    } catch {
      // ignore
    }
  }
}

/**
 * Run the Anthropic OAuth login flow. Calls `onAuth(url)` with the URL the
 * user must visit in their browser; resolves with credentials once the
 * callback hits the local server pi-ai spins up.
 */
export async function startAnthropicLogin(
  store: OAuthStore,
  onAuth: (url: string) => void,
): Promise<OAuthCredentials> {
  const creds = await loginAnthropic({
    onAuth: (info: { url: string }) => {
      log.info("anthropic oauth url", { url: info.url });
      onAuth(info.url);
    },
    onPrompt: async () => {
      // We don't surface a prompt UX over the wire — if the local callback
      // server doesn't fire we just fail rather than asking the user to
      // paste a URL. They can retry the login from the Mac UI.
      throw new Error("interactive prompt not supported in sidecar OAuth flow");
    },
    onProgress: (msg: string) => log.info("anthropic oauth progress", { msg }),
  });
  await store.save("anthropic", creds);
  return creds;
}

/**
 * Get a valid access token for Anthropic, refreshing if needed.
 * Throws if the user hasn't logged in yet.
 */
export async function getAnthropicAccessToken(store: OAuthStore): Promise<string> {
  const creds = await store.load("anthropic");
  if (!creds || !creds.refresh) {
    throw new Error("not logged in to Anthropic OAuth");
  }
  // Refresh ~5 minutes before expiry so concurrent calls don't race.
  const REFRESH_SLACK_MS = 5 * 60_000;
  const expiresAt = typeof creds.expires === "number" ? creds.expires : 0;
  if (Date.now() >= expiresAt - REFRESH_SLACK_MS) {
    log.info("refreshing anthropic oauth token");
    const fresh = await refreshAnthropicToken(creds.refresh);
    await store.save("anthropic", fresh);
    return anthropicOAuthProvider.getApiKey(fresh);
  }
  return anthropicOAuthProvider.getApiKey(creds);
}

/** Whether we have valid-looking creds for Anthropic OAuth. */
export async function hasAnthropicCreds(store: OAuthStore): Promise<boolean> {
  const creds = await store.load("anthropic");
  return Boolean(creds && creds.refresh);
}

// ── OpenAI Codex (ChatGPT) OAuth ──────────────────────────────────────────

export async function startOpenAICodexLogin(
  store: OAuthStore,
  onAuth: (url: string) => void,
): Promise<OAuthCredentials> {
  const creds = await loginOpenAICodex({
    onAuth: (info: { url: string }) => {
      log.info("openai-codex oauth url", { url: info.url });
      onAuth(info.url);
    },
    onPrompt: async () => {
      throw new Error("interactive prompt not supported in sidecar OAuth flow");
    },
    onProgress: (msg: string) => log.info("openai-codex oauth progress", { msg }),
  });
  await store.save("openai-codex", creds);
  return creds;
}

export async function getOpenAICodexAccessToken(store: OAuthStore): Promise<string> {
  const creds = await store.load("openai-codex");
  if (!creds || !creds.refresh) {
    throw new Error("not logged in to ChatGPT OAuth");
  }
  const REFRESH_SLACK_MS = 5 * 60_000;
  const expiresAt = typeof creds.expires === "number" ? creds.expires : 0;
  if (Date.now() >= expiresAt - REFRESH_SLACK_MS) {
    log.info("refreshing openai-codex oauth token");
    const fresh = await refreshOpenAICodexToken(creds.refresh);
    await store.save("openai-codex", fresh);
    return openaiCodexOAuthProvider.getApiKey(fresh);
  }
  return openaiCodexOAuthProvider.getApiKey(creds);
}

export async function hasOpenAICodexCreds(store: OAuthStore): Promise<boolean> {
  const creds = await store.load("openai-codex");
  return Boolean(creds && creds.refresh);
}

// ── Anthropic Console (API Usage Billing) ─────────────────────────────────

const CONSOLE_API_KEY_MINT_URL =
  "https://api.anthropic.com/api/oauth/claude_cli/create_api_key";

/**
 * Run the Anthropic Console OAuth dance, then mint a Console API key
 * from the resulting access token. The OAuth tokens are deliberately
 * discarded — the only artifact we keep is the minted API key, which
 * the caller is expected to stash in the Mac's Keychain.
 *
 * Distinct from {@link startAnthropicLogin} (Pro/Max). The two flows
 * use the same client_id and scopes but different authorize hosts:
 * Pro/Max → claude.ai (requires Claude Code seat on the consumer
 * account); Console → platform.claude.com (authenticates against the
 * user's Anthropic Console org instead). See {@link loginAnthropicConsole}.
 */
export async function startAnthropicConsoleLogin(
  onAuth: (url: string) => void,
): Promise<{ apiKey: string }> {
  const creds = await loginAnthropicConsole(onAuth);
  log.info("anthropic console oauth credentials exchanged");
  const apiKey = await mintAnthropicApiKey(creds.access);
  return { apiKey };
}

/**
 * Exchange an Anthropic OAuth access token for a real Console API key
 * (`sk-ant-api03-…`). The minted key is owned by the user's Console org
 * and bills as ordinary API usage from that point on.
 *
 * Exported separately from {@link startAnthropicConsoleLogin} so it can
 * be unit-tested without invoking the real OAuth dance.
 */
export async function mintAnthropicApiKey(accessToken: string): Promise<string> {
  const res = await fetch(CONSOLE_API_KEY_MINT_URL, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      "Accept": "application/json",
    },
    body: JSON.stringify({}),
    signal: AbortSignal.timeout(30_000),
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(
      `Anthropic Console API key mint failed. status=${res.status}; body=${body}`,
    );
  }
  const data = (await res.json()) as { raw_key?: string; key?: string };
  const key = data.raw_key ?? data.key;
  if (!key || !key.startsWith("sk-ant-api")) {
    throw new Error(
      `Anthropic Console API key mint returned unexpected payload: ${JSON.stringify(data)}`,
    );
  }
  return key;
}

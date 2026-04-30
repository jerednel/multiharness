import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { log } from "./logger.js";

/**
 * Anthropic Console (API Usage Billing) OAuth flow.
 *
 * Distinct from pi-ai's `loginAnthropic`, which authorizes against
 * `https://claude.ai/oauth/authorize` and authenticates the user as a
 * Pro/Max consumer (requires a Claude Code seat on the consumer
 * account). This flow authorizes against `platform.claude.com` instead,
 * authenticating the user as a member of their Anthropic Console org —
 * the access token can then be exchanged for a real `sk-ant-api03-…`
 * key via the mint endpoint, billed as ordinary API usage.
 *
 * Same client_id and scopes as the Pro/Max flow; the only practical
 * difference is the authorize host and a dynamic callback port.
 */

const CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e";
const AUTHORIZE_URL = "https://platform.claude.com/oauth/authorize";
const TOKEN_URL = "https://platform.claude.com/v1/oauth/token";
const CALLBACK_HOST = "127.0.0.1";
const CALLBACK_PATH = "/callback";
const SCOPES =
  "org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload";

export interface ConsoleOAuthCredentials {
  access: string;
  refresh: string;
  expires: number;
}

function base64url(buf: Buffer): string {
  return buf.toString("base64url");
}

function generatePkce(): { verifier: string; challenge: string } {
  const verifier = base64url(randomBytes(32));
  const challenge = base64url(createHash("sha256").update(verifier).digest());
  return { verifier, challenge };
}

function generateState(): string {
  return base64url(randomBytes(24));
}

interface CallbackResult {
  code: string;
  state: string;
}

interface CallbackServer {
  port: number;
  redirectUri: string;
  waitForCallback: () => Promise<CallbackResult>;
  close: () => void;
}

function startCallbackServer(expectedState: string): Promise<CallbackServer> {
  return new Promise((resolve, reject) => {
    let resolveResult: ((r: CallbackResult) => void) | null = null;
    let rejectResult: ((e: Error) => void) | null = null;
    const callbackPromise = new Promise<CallbackResult>((res, rej) => {
      resolveResult = res;
      rejectResult = rej;
    });

    const server = createServer((req: IncomingMessage, res: ServerResponse) => {
      try {
        const url = new URL(req.url || "", "http://localhost");
        if (url.pathname !== CALLBACK_PATH) {
          res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
          res.end("Not found");
          return;
        }
        const code = url.searchParams.get("code");
        const state = url.searchParams.get("state");
        const errorParam = url.searchParams.get("error");
        if (errorParam) {
          res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
          res.end(`Authentication did not complete: ${errorParam}`);
          rejectResult?.(new Error(`OAuth error from authorize endpoint: ${errorParam}`));
          return;
        }
        if (!code || !state) {
          res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
          res.end("Missing code or state parameter.");
          rejectResult?.(new Error("Missing code or state on OAuth callback"));
          return;
        }
        if (state !== expectedState) {
          res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
          res.end("State mismatch.");
          rejectResult?.(new Error("OAuth state mismatch"));
          return;
        }
        res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
        res.end(
          `<!doctype html><html><body style="font-family:-apple-system,sans-serif;max-width:32em;margin:4em auto;padding:0 1em">` +
            `<h2>Anthropic authentication completed</h2>` +
            `<p>Multiharness has minted an API key in your Console org. You can close this window.</p>` +
            `</body></html>`,
        );
        resolveResult?.({ code, state });
      } catch (e) {
        res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
        res.end("Internal error");
        rejectResult?.(e instanceof Error ? e : new Error(String(e)));
      }
    });
    server.on("error", (err) => reject(err));
    server.listen(0, CALLBACK_HOST, () => {
      const addr = server.address();
      const port = typeof addr === "object" && addr ? addr.port : 0;
      if (!port) {
        server.close();
        reject(new Error("Failed to bind OAuth callback server"));
        return;
      }
      resolve({
        port,
        redirectUri: `http://localhost:${port}${CALLBACK_PATH}`,
        waitForCallback: () => callbackPromise,
        close: () => server.close(),
      });
    });
  });
}

async function exchangeAuthorizationCode(
  code: string,
  state: string,
  verifier: string,
  redirectUri: string,
): Promise<ConsoleOAuthCredentials> {
  const res = await fetch(TOKEN_URL, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify({
      grant_type: "authorization_code",
      client_id: CLIENT_ID,
      code,
      state,
      redirect_uri: redirectUri,
      code_verifier: verifier,
    }),
    signal: AbortSignal.timeout(30_000),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(
      `Anthropic Console token exchange failed. status=${res.status}; body=${text}`,
    );
  }
  let data: { access_token?: string; refresh_token?: string; expires_in?: number };
  try {
    data = JSON.parse(text);
  } catch {
    throw new Error(`Anthropic Console token exchange returned invalid JSON: ${text}`);
  }
  if (
    !data.access_token ||
    !data.refresh_token ||
    typeof data.expires_in !== "number"
  ) {
    throw new Error(
      `Anthropic Console token exchange missing required fields: ${text}`,
    );
  }
  return {
    access: data.access_token,
    refresh: data.refresh_token,
    expires: Date.now() + data.expires_in * 1000 - 5 * 60_000,
  };
}

/**
 * Run the Anthropic Console OAuth dance. The caller's `onAuth` callback
 * receives the authorize URL; the user opens it in their browser and
 * completes the login. Resolves with the resulting OAuth credentials.
 */
export async function loginAnthropicConsole(
  onAuth: (url: string) => void,
): Promise<ConsoleOAuthCredentials> {
  const { verifier, challenge } = generatePkce();
  const state = generateState();
  const server = await startCallbackServer(state);
  try {
    const params = new URLSearchParams({
      code: "true",
      client_id: CLIENT_ID,
      response_type: "code",
      redirect_uri: server.redirectUri,
      scope: SCOPES,
      code_challenge: challenge,
      code_challenge_method: "S256",
      state,
    });
    const authUrl = `${AUTHORIZE_URL}?${params.toString()}`;
    log.info("anthropic console authorize url", { port: server.port });
    onAuth(authUrl);
    const { code } = await server.waitForCallback();
    log.info("anthropic console oauth code received");
    return await exchangeAuthorizationCode(
      code,
      state,
      verifier,
      server.redirectUri,
    );
  } finally {
    server.close();
  }
}

# Anthropic Console (API Usage Billing) Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a "Sign in with Claude (API Usage Billing)" provider option that runs the same Anthropic OAuth dance as the existing Pro/Max flow, but mints a real `sk-ant-api03-…` API key in the user's Console org and stores it like any other Anthropic API-key provider.

**Architecture:** The OAuth dance is unchanged from pi-ai's `loginAnthropic` (same client_id, same scopes — already includes `org:create_api_key`). After login succeeds, the sidecar exchanges the access token for a minted API key via `POST https://api.anthropic.com/api/oauth/claude_cli/create_api_key`, returns the key to the Mac, and discards the OAuth tokens. The Mac stores the key in macOS Keychain and registers a normal `pi-known anthropic` provider — runtime behavior is then identical to a manually-pasted Anthropic key.

**Tech Stack:** Bun + TypeScript (sidecar), SwiftUI (Mac UI), `@mariozechner/pi-ai/oauth` (existing OAuth dance), `bun:test` (sidecar tests).

**Spec:** `docs/superpowers/specs/2026-04-29-anthropic-console-oauth-design.md`

## File Map

| File | Action | Responsibility |
|---|---|---|
| `sidecar/src/oauthStore.ts` | modify | Add `mintAnthropicApiKey(accessToken)` helper and `startAnthropicConsoleLogin(onAuth)` orchestration. |
| `sidecar/src/methods.ts` | modify | Register `auth.anthropic.console.start` dispatcher entry. |
| `sidecar/test/oauthConsole.test.ts` | create | Unit-test the mint helper against a mocked `fetch`. |
| `Sources/MultiharnessCore/Stores/AppStore.swift` | modify | Add `anthropicConsoleLoginInProgress`/`Error` state vars + `signInWithAnthropicConsole()` method. |
| `Sources/Multiharness/App.swift` | modify | Route new `anthropic_console_auth_url` event to existing `openAnthropicAuthURL`. |
| `Sources/Multiharness/Views/Sheets.swift` | modify | Add a Console sign-in button in `ProvidersTab`. |

No iOS changes. No schema migrations. No new dependencies.

---

### Task 1: Sidecar — mint helper with unit tests

**Files:**
- Create: `sidecar/test/oauthConsole.test.ts`
- Modify: `sidecar/src/oauthStore.ts` (export new helper)

The mint helper is the entire piece of risk in this feature (endpoint path and response shape are guesses per the spec). Test it in isolation, then wire it up.

- [ ] **Step 1: Write the failing test file**

Create `sidecar/test/oauthConsole.test.ts`:

```typescript
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mintAnthropicApiKey } from "../src/oauthStore.js";

describe("mintAnthropicApiKey", () => {
  const realFetch = globalThis.fetch;
  let calls: Array<{ url: string; init: RequestInit | undefined }> = [];

  beforeEach(() => {
    calls = [];
  });

  afterEach(() => {
    globalThis.fetch = realFetch;
  });

  function mockFetch(response: { status: number; body: string }) {
    globalThis.fetch = (async (url: string, init?: RequestInit) => {
      calls.push({ url: String(url), init });
      return new Response(response.body, { status: response.status });
    }) as typeof fetch;
  }

  it("returns the minted key when the response uses raw_key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ raw_key: "sk-ant-api03-abc" }) });
    const key = await mintAnthropicApiKey("access-token-123");
    expect(key).toBe("sk-ant-api03-abc");
    expect(calls).toHaveLength(1);
    expect(calls[0]!.url).toBe(
      "https://api.anthropic.com/api/oauth/claude_cli/create_api_key",
    );
    const headers = calls[0]!.init?.headers as Record<string, string> | undefined;
    expect(headers?.["Authorization"]).toBe("Bearer access-token-123");
  });

  it("returns the minted key when the response uses key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ key: "sk-ant-api03-xyz" }) });
    const key = await mintAnthropicApiKey("tok");
    expect(key).toBe("sk-ant-api03-xyz");
  });

  it("throws with the response body included on a 4xx", async () => {
    mockFetch({ status: 401, body: '{"error":"unauthorized"}' });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/401/);
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unauthorized/);
  });

  it("throws when the response body has no key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ unrelated: "field" }) });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unexpected payload/);
  });

  it("throws when the key does not look like an Anthropic key", async () => {
    mockFetch({ status: 200, body: JSON.stringify({ raw_key: "not-an-anthropic-key" }) });
    await expect(mintAnthropicApiKey("tok")).rejects.toThrow(/unexpected payload/);
  });
});
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd sidecar && bun test test/oauthConsole.test.ts`
Expected: FAIL with import error or "mintAnthropicApiKey is not a function" — the helper doesn't exist yet.

- [ ] **Step 3: Implement the helper in `sidecar/src/oauthStore.ts`**

Add this function at the end of the file (after `hasOpenAICodexCreds`):

```typescript
// ── Anthropic Console (API Usage Billing) ─────────────────────────────────

const CONSOLE_API_KEY_MINT_URL =
  "https://api.anthropic.com/api/oauth/claude_cli/create_api_key";

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
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `cd sidecar && bun test test/oauthConsole.test.ts`
Expected: 5 passing tests.

- [ ] **Step 5: Run the full sidecar test + typecheck to ensure nothing else broke**

Run: `cd sidecar && bun test && bun run typecheck`
Expected: all tests pass, no TS errors.

- [ ] **Step 6: Commit**

```bash
git add sidecar/src/oauthStore.ts sidecar/test/oauthConsole.test.ts
git commit -m "$(cat <<'EOF'
sidecar: add Anthropic Console API key mint helper

Exchanges an OAuth access token (with org:create_api_key scope)
for a real sk-ant-api03 key via Anthropic's Claude CLI mint
endpoint. Tested against a mocked fetch — endpoint path and
response shape are educated guesses that will be verified during
the manual smoke test before merge.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Sidecar — `startAnthropicConsoleLogin` + dispatcher entry

**Files:**
- Modify: `sidecar/src/oauthStore.ts` (add orchestration function)
- Modify: `sidecar/src/methods.ts` (register new RPC method)

The orchestration is glue: run pi-ai's `loginAnthropic`, pass the resulting access token through `mintAnthropicApiKey`, return the key. Not unit-tested directly — both pieces it composes are tested elsewhere (pi-ai upstream + Task 1).

- [ ] **Step 1: Add `startAnthropicConsoleLogin` to `sidecar/src/oauthStore.ts`**

Insert immediately above `mintAnthropicApiKey` (so the function the dispatcher imports is at the top of the section):

```typescript
/**
 * Run the Anthropic OAuth dance, then mint a Console API key from the
 * resulting access token. The OAuth tokens are deliberately discarded —
 * the only artifact we keep is the minted API key, which the caller is
 * expected to stash in the Mac's Keychain.
 */
export async function startAnthropicConsoleLogin(
  onAuth: (url: string) => void,
): Promise<{ apiKey: string }> {
  const creds = await loginAnthropic({
    onAuth: (info: { url: string }) => {
      log.info("anthropic console oauth url", { url: info.url });
      onAuth(info.url);
    },
    onPrompt: async () => {
      throw new Error("interactive prompt not supported in sidecar OAuth flow");
    },
    onProgress: (msg: string) => log.info("anthropic console oauth progress", { msg }),
  });
  const apiKey = await mintAnthropicApiKey(creds.access);
  return { apiKey };
}
```

(`loginAnthropic` and `log` are already imported at the top of the file.)

- [ ] **Step 2: Register the dispatcher entry in `sidecar/src/methods.ts`**

In the import block at the top of the file (lines 9-15), add `startAnthropicConsoleLogin` to the named imports from `./oauthStore.js`:

```typescript
import {
  hasAnthropicCreds,
  hasOpenAICodexCreds,
  startAnthropicLogin,
  startAnthropicConsoleLogin,
  startOpenAICodexLogin,
  type OAuthStore,
} from "./oauthStore.js";
```

Then, inside the `// ── OAuth ──` section (immediately after the `auth.anthropic.start` registration on line 173, before the `auth.openai.status` registration), add:

```typescript
  d.register("auth.anthropic.console.start", async () => {
    try {
      const { apiKey } = await startAnthropicConsoleLogin((url) => {
        sink("", { type: "anthropic_console_auth_url", url });
      });
      sink("", { type: "anthropic_console_auth_complete", ok: true });
      return { apiKey };
    } catch (e) {
      const reason = e instanceof Error ? e.message : String(e);
      log.error("anthropic console oauth login failed", { reason });
      sink("", { type: "anthropic_console_auth_complete", ok: false, error: reason });
      throw e;
    }
  });
```

- [ ] **Step 3: Run typecheck and full test suite**

Run: `cd sidecar && bun run typecheck && bun test`
Expected: no TS errors, all tests pass (the new function isn't directly tested, but the type checker validates the shape).

- [ ] **Step 4: Commit**

```bash
git add sidecar/src/oauthStore.ts sidecar/src/methods.ts
git commit -m "$(cat <<'EOF'
sidecar: register auth.anthropic.console.start RPC method

Runs the existing Anthropic OAuth dance, mints a Console API
key, returns { apiKey } and emits anthropic_console_auth_url /
_complete events for the Mac's browser-launch handler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Mac — `signInWithAnthropicConsole` in `AppStore`

**Files:**
- Modify: `Sources/MultiharnessCore/Stores/AppStore.swift`

- [ ] **Step 1: Add the new state vars**

In `AppStore.swift`, after line 35 (`public var openaiLoginError: String?`), add two new vars matching the pattern:

```swift
    /// True while an Anthropic Console (API Usage Billing) login is in flight.
    public var anthropicConsoleLoginInProgress: Bool = false
    public var anthropicConsoleLoginError: String?
```

- [ ] **Step 2: Add the `signInWithAnthropicConsole` method**

In `AppStore.swift`, after the existing `signInWithChatGPT` method (around line 431, before `openOpenAIAuthURL`), add:

```swift
    /// Kick off the Anthropic Console OAuth flow. Unlike Pro/Max, the
    /// sidecar mints a real Console API key (sk-ant-api03-…) and returns
    /// it; we stash the key in Keychain and register a normal pi-known
    /// anthropic provider. Subsequent calls bill as API usage on the
    /// user's Console org.
    public func signInWithAnthropicConsole() async {
        guard let client = env.control else {
            anthropicConsoleLoginError = "control client not connected"
            return
        }
        anthropicConsoleLoginInProgress = true
        anthropicConsoleLoginError = nil
        defer { anthropicConsoleLoginInProgress = false }
        do {
            let result = try await client.call(
                method: "auth.anthropic.console.start",
                params: [:]
            )
            guard
                let dict = result as? [String: Any],
                let apiKey = dict["apiKey"] as? String,
                apiKey.hasPrefix("sk-ant-api")
            else {
                anthropicConsoleLoginError = "sidecar returned an unexpected payload"
                return
            }
            addProvider(
                name: "Claude (API Usage Billing)",
                kind: .piKnown,
                piProvider: "anthropic",
                baseUrl: nil,
                defaultModelId: nil,
                apiKey: apiKey
            )
        } catch {
            anthropicConsoleLoginError = String(describing: error)
        }
    }
```

(`addProvider` already handles Keychain storage when a non-empty `apiKey` is passed — see `AppStore.swift:237-268`.)

- [ ] **Step 3: Build to verify compilation**

Run: `swift build`
Expected: build succeeds with no errors.

- [ ] **Step 4: Commit**

```bash
git add Sources/MultiharnessCore/Stores/AppStore.swift
git commit -m "$(cat <<'EOF'
AppStore: add signInWithAnthropicConsole

Calls auth.anthropic.console.start, validates the returned
sk-ant-api03 key, and adds a pi-known anthropic provider with
the key stored in Keychain via the existing addProvider path.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Mac — route the new auth-URL event to the browser

**Files:**
- Modify: `Sources/Multiharness/App.swift:139-145`

The existing handler routes `anthropic_auth_url` events to `appStore.openAnthropicAuthURL(_:)`. We add a sibling case for the Console event that calls the same handler — the URL-opening logic is identical for both flows.

- [ ] **Step 1: Add the new event case**

In `Sources/Multiharness/App.swift`, find the block:

```swift
        if event.type == "anthropic_auth_url" {
            let urlString = event.payload["url"] as? String
            Task { @MainActor in
                if let urlString { self.appStore?.openAnthropicAuthURL(urlString) }
            }
            return
        }
```

Add an identical block immediately after it (before the `openai_auth_url` block):

```swift
        if event.type == "anthropic_console_auth_url" {
            let urlString = event.payload["url"] as? String
            Task { @MainActor in
                if let urlString { self.appStore?.openAnthropicAuthURL(urlString) }
            }
            return
        }
```

- [ ] **Step 2: Build to verify compilation**

Run: `swift build`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/Multiharness/App.swift
git commit -m "$(cat <<'EOF'
App: route anthropic_console_auth_url event to browser

Reuses the existing openAnthropicAuthURL handler — the URL-
opening logic is the same for both Pro/Max and Console flows.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Mac — Console sign-in button in Providers tab

**Files:**
- Modify: `Sources/Multiharness/Views/Sheets.swift` (in `ProvidersTab`, around lines 327-378)

Add a third button below the existing "Sign in with ChatGPT" row, mirroring its pattern but checking for a `pi-known anthropic` provider whose name is "Claude (API Usage Billing)" (so it doesn't false-match on a manually-pasted Anthropic key).

- [ ] **Step 1: Add the button row**

In `Sources/Multiharness/Views/Sheets.swift`, find the closing `}` of the second `HStack(spacing: 8) { ... }` block at line 377 (immediately before the `ScrollView` that follows). Insert this third `HStack` before that `ScrollView`:

```swift
                HStack(spacing: 8) {
                    Button {
                        Task { await appStore.signInWithAnthropicConsole() }
                    } label: {
                        HStack(spacing: 6) {
                            if appStore.anthropicConsoleLoginInProgress {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "creditcard")
                            }
                            Text(hasConsoleProvider(appStore)
                                 ? "Re-authenticate Claude Console"
                                 : "Sign in with Claude (API Usage Billing)")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(appStore.anthropicConsoleLoginInProgress)
                    if let err = appStore.anthropicConsoleLoginError {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                    } else if hasConsoleProvider(appStore) {
                        Text("Signed in").font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
```

- [ ] **Step 2: Add the `hasConsoleProvider` helper**

In the same file, inside the `ProvidersTab` struct (anywhere — convention is after the `body`), add:

```swift
    private func hasConsoleProvider(_ store: AppStore) -> Bool {
        store.providers.contains { p in
            p.kind == .piKnown
            && p.piProvider == "anthropic"
            && p.name == "Claude (API Usage Billing)"
        }
    }
```

This is intentionally name-keyed: a manually-pasted Anthropic key is also `kind: .piKnown, piProvider: "anthropic"`, but won't share the exact name string.

- [ ] **Step 3: Build the app bundle and verify it compiles**

Run: `bash scripts/build-app.sh`
Expected: `dist/Multiharness.app` is produced, signing succeeds.

- [ ] **Step 4: Smoke-launch the app and verify the button renders**

Run: `open dist/Multiharness.app` (or launch from Finder).
In the app, open Settings → Providers tab.
Verify: three sign-in buttons stack vertically — "Sign in with Claude" (purple), "Sign in with ChatGPT" (green), "Sign in with Claude (API Usage Billing)" (blue).

Do NOT click the new button yet — that's Task 6.

- [ ] **Step 5: Commit**

```bash
git add Sources/Multiharness/Views/Sheets.swift
git commit -m "$(cat <<'EOF'
Settings: add Claude (API Usage Billing) sign-in button

Sits alongside the existing Pro/Max and ChatGPT sign-in
buttons. Identifies an existing Console provider by name
("Claude (API Usage Billing)") rather than by kind, since
the resulting provider is a regular pi-known anthropic
record indistinguishable from a manually-pasted key.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Manual smoke test against a real Anthropic Console account

**Files:** none (verification only).

This is the only path that validates the two known unknowns from the spec: the mint endpoint URL (`/api/oauth/claude_cli/create_api_key`) and response shape (`raw_key` vs `key`). CI cannot do this — Anthropic's OAuth flow can't run headlessly.

- [ ] **Step 1: Build the app fresh**

Run: `bash scripts/build-app.sh && open dist/Multiharness.app`

- [ ] **Step 2: Click the new "Sign in with Claude (API Usage Billing)" button**

Watch for:
- A browser window opens to `https://claude.ai/oauth/authorize?...` (pi-ai's URL — close enough to `platform.claude.com` for the auth dance).
- After authenticating, the browser shows pi-ai's "Anthropic authentication completed" page.
- The Settings panel's button label changes to "Re-authenticate Claude Console" with green "Signed in".
- A new provider "Claude (API Usage Billing)" appears in the providers list below.

- [ ] **Step 3: If the mint step fails**, capture the error from the Settings panel — it includes Anthropic's response body. Diagnose:
  - **404 with HTML response** → endpoint path is wrong. Sniff Claude Code CLI's network traffic during a Console login (`mitmproxy --mode upstream` or Charles Proxy) to find the real path. Update `CONSOLE_API_KEY_MINT_URL` in `sidecar/src/oauthStore.ts` and the test.
  - **401/403 with JSON** → access token is correct but missing a scope or header. Check whether the request needs `anthropic-beta` or `anthropic-version` headers (compare to Claude Code CLI traffic).
  - **200 with unexpected JSON shape** → the key is in some field other than `raw_key` or `key`. Update both the helper and the test, then re-run.

  After any fix, restart from Step 1.

- [ ] **Step 4: Verify the minted key actually works**

Create a workspace using the new "Claude (API Usage Billing)" provider, send a single prompt, and confirm:
- The agent responds (`models.list` and a real inference call both succeed).
- The user's Console org dashboard at console.anthropic.com shows a new API key with a recent "Created" timestamp, and the day's API usage reflects the test call.

- [ ] **Step 5: Document the verification result in the PR description**

Include:
- Confirmed mint endpoint URL.
- Confirmed response shape.
- Screenshot of the Console org showing the minted key.

- [ ] **Step 6: If the mint URL or response shape required code changes in Step 3, commit them**

```bash
git add sidecar/src/oauthStore.ts sidecar/test/oauthConsole.test.ts
git commit -m "$(cat <<'EOF'
sidecar: correct Anthropic Console mint endpoint after smoke test

Updates URL/response handling based on the actual mint response
observed against a real Console account.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Verification before declaring done

- [ ] `cd sidecar && bun test && bun run typecheck` — all green.
- [ ] `swift build && swift test` — all green.
- [ ] `bash scripts/build-app.sh` — produces a signed `.app` bundle.
- [ ] Manual smoke test (Task 6) completed successfully against a real Console account, with the result documented.
- [ ] No new files in `oauth/` data dir after Console sign-in (the OAuth tokens should be discarded — only the API key in Keychain should persist).
- [ ] Existing Pro/Max sign-in still works (regression check).

# Anthropic Console Login (API Usage Billing) — Design

**Date:** 2026-04-29
**Status:** Proposed

## Context

Multiharness today exposes one Anthropic OAuth provider option:
"Sign in with Claude (Pro/Max)". It runs the OAuth dance from
`@mariozechner/pi-ai/oauth` (`loginAnthropic`), stashes the resulting
access + refresh tokens at `~/Library/Application Support/Multiharness/oauth/anthropic.json`,
and on every Anthropic call resolves the access token via an async
`getApiKey` callback on the `Agent`. Anthropic recognizes the access
token and bills the call against the user's Pro/Max subscription.

A second flow exists in the wild (it's what `claude /login` →
"API Console Account" produces): the user signs in with the same OAuth
client, but instead of using the access token directly for inference,
the access token is exchanged for a real `sk-ant-api03-…` API key in
the user's Anthropic Console org. From then on, inference calls use
that minted key and bill as ordinary API usage.

This spec adds that second option to Multiharness.

## Goals

- Let the user sign in with their Anthropic Console account and arrive
  at a working provider with one click.
- Bill via API usage (Console org) rather than via Pro/Max subscription.
- Coexist with the existing "Sign in with Claude (Pro/Max)" option;
  the user can have both, neither, or either.
- Touch as little of the existing provider plumbing as possible.

## Non-goals

- Any provisioning UX inside Multiharness (no "create org",
  no "set spend limit" — the user does that in the Anthropic Console).
- Refreshing or rotating the minted API key from inside the app.
  If Anthropic revokes the key, the user re-runs sign-in.
- iOS-initiated OAuth. iOS never sees keys; this remains Mac-only.

## Key insight

The OAuth URL the Console flow sends users to is identical to the URL
pi-ai's `loginAnthropic` already produces — same `client_id`, same
scopes (`org:create_api_key user:profile user:inference
user:sessions:claude_code user:mcp_servers user:file_upload`). The
only practical differences are:

1. Authorize host (`platform.claude.com` vs `claude.ai`) — cosmetic;
   both work.
2. What the integrator does *with the credentials* afterward.

So the Console flow is not a separate OAuth flow. It's
**OAuth-assisted API key provisioning**: run the same dance, then make
one extra HTTP call to mint a key, then forget the OAuth tokens.

## Architecture

```
User clicks "Sign in with Claude (API Usage Billing)" in Settings
        │
        ▼
Mac → sidecar:  call("auth.anthropic.console.start", {})
        │
        ▼
Sidecar:  loginAnthropic()    ← reuses pi-ai's existing OAuth dance,
        │                       opens browser, waits on local callback
        │
        ▼
Sidecar:  POST  api.anthropic.com  /api/oauth/claude_cli/create_api_key
        │       headers: Authorization: Bearer <access_token>
        │
        ▼
Sidecar  →  Mac:  { apiKey: "sk-ant-api03-…" }
        │
        ▼
Mac:  Keychain.save(service: "com.multiharness.providers",
                    account: <provider_id>, value: apiKey)
      AppStore.addProvider(ProviderRecord {
          kind: .piKnown, provider: "anthropic",
          name: "Claude (API Usage Billing)",
          modelId: "claude-sonnet-4-5", keychainAccount: <id>
      })
```

After this dance, nothing distinguishes the resulting provider from one
the user created by pasting an API key. No OAuth tokens persist
anywhere. The agent runtime path (`AgentSession.getApiKey`) is unchanged.

## Components

### Sidecar — new function in `sidecar/src/oauthStore.ts`

```ts
export async function startAnthropicConsoleLogin(
  onAuth: (url: string) => void,
): Promise<{ apiKey: string }> {
  const creds = await loginAnthropic({
    onAuth: (info) => onAuth(info.url),
    onPrompt: async () => { throw new Error("interactive prompt not supported"); },
    onProgress: (msg) => log.info("anthropic console oauth progress", { msg }),
  });
  const apiKey = await mintAnthropicApiKey(creds.access);
  return { apiKey };
}

async function mintAnthropicApiKey(accessToken: string): Promise<string> {
  const res = await fetch("https://api.anthropic.com/api/oauth/claude_cli/create_api_key", {
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
    throw new Error(`API key mint failed. status=${res.status}; body=${body}`);
  }
  const data = await res.json() as { raw_key?: string; key?: string };
  const key = data.raw_key ?? data.key;
  if (!key || !key.startsWith("sk-ant-api")) {
    throw new Error(`API key mint returned unexpected payload: ${JSON.stringify(data)}`);
  }
  return key;
}
```

The `OAuthStore` parameter from `startAnthropicLogin` is intentionally
omitted: nothing is persisted in the sidecar's `oauth/` dir for this
flow.

### Sidecar — new dispatcher entry in `sidecar/src/methods.ts`

```ts
d.register("auth.anthropic.console.start", async () => {
  const { apiKey } = await startAnthropicConsoleLogin((url) => {
    sink.publish({ event: "anthropic_console_auth_url", params: { url } });
  });
  sink.publish({ event: "anthropic_console_auth_complete", params: {} });
  return { apiKey };
});
```

Mirrors the shape of `auth.anthropic.start`. The two server-pushed
events let the Mac open the browser at the right moment and show a
"Sign in succeeded" affordance in the sheet.

### Mac — new method in `Sources/Multiharness/AppStore.swift`

```swift
func signInWithAnthropicConsole() async throws {
    let result = try await client.call(
        method: "auth.anthropic.console.start",
        params: [:]
    )
    guard
        let dict = result as? [String: Any],
        let apiKey = dict["apiKey"] as? String,
        apiKey.hasPrefix("sk-ant-api")
    else {
        throw AppError.unexpectedResponse("auth.anthropic.console.start")
    }

    let providerId = UUID().uuidString
    try Keychain.save(
        service: "com.multiharness.providers",
        account: providerId,
        value: apiKey
    )

    addProvider(ProviderRecord(
        id: providerId,
        kind: .piKnown,
        provider: "anthropic",
        name: "Claude (API Usage Billing)",
        modelId: "claude-sonnet-4-5",
        keychainAccount: providerId,
        baseUrl: nil
    ))
}
```

If the Keychain write fails after a successful mint, the
`ProviderRecord` is *not* added. The minted key is orphaned in the
user's Console org (acceptable — they can revoke it from
console.anthropic.com), and the user re-runs sign-in.

### Mac — auth-URL handler

The existing `openAnthropicAuthURL` subscribes to the
`anthropic_auth_url` event. The new flow needs the same behavior for
`anthropic_console_auth_url`. Refactor the existing handler to take
the event name as a parameter (third copy makes a function); both
flows then share one implementation.

### Mac — UI

In `Sources/MultiharnessClient/Models/Models.swift`, add a sibling to
the existing "Sign in with Claude (Pro/Max)" preset:

```swift
ProviderPreset(
    id: "anthropic-console-signin",
    name: "Sign in with Claude (API Usage Billing)",
    requiresConsoleSignIn: true,
    // ...
)
```

`requiresConsoleSignIn: true` is a marker the Add-provider sheet uses
to render a "Sign in" button instead of an API-key field, dispatching
to `appStore.signInWithAnthropicConsole()`. Same UX shape as the
existing Pro/Max button.

After sign-in the new provider appears in the list as
**"Claude (API Usage Billing)"**, distinguishable from Pro/Max at a
glance.

### iOS

No changes. iOS lists providers by name in the picker; the new
"Claude (API Usage Billing)" entry will appear in the same list as
Pro/Max once added on the Mac. iOS-initiated OAuth remains out of
scope per the existing model (iOS never sees keys).

## Data flow & state

| State | Where it lives | When written | When read |
|---|---|---|---|
| OAuth refresh token | nowhere | never | n/a |
| OAuth access token | sidecar process memory only | during `loginAnthropic` | once, to mint key, then dropped |
| Minted `sk-ant-api03-…` | macOS Keychain (`com.multiharness.providers`) | after sign-in | every Anthropic API call (resolved by existing `getApiKey` static-key path in `AgentSession.ts`) |
| `ProviderRecord` | `state.db` `providers` table | after sign-in | provider picker, model picker, agent creation |

## Error handling

- **User cancels in browser** — callback server in pi-ai times out /
  errors; the RPC errors out; the sheet shows the error and stays
  open for retry. Same path as the existing Pro/Max flow.
- **Mint endpoint returns 4xx** (no Console org, payment method
  missing, scope rejected) — sidecar wraps Anthropic's response body
  into the RPC error; sheet displays it; user fixes the underlying
  Console-account issue and retries.
- **Network failure mid-mint** — same; user retries.
- **Keychain write failure on Mac** — see above; minted key is
  orphaned in Console; no `ProviderRecord` is added; user retries.
- **Endpoint path or response shape differs from this spec** — see
  "Known unknowns" below.

## Known unknowns

These are details the spec is *guessing at*. Each will be verified
during implementation; if any is wrong, the fix is one line.

1. **Mint endpoint path.** Spec assumes
   `POST https://api.anthropic.com/api/oauth/claude_cli/create_api_key`
   with `Authorization: Bearer <access_token>`. Justification: the
   `org:create_api_key` scope and Claude Code CLI's
   reverse-engineered behavior. Verification:
   - inspect Claude Code CLI network traffic during a Console login
     (Charles Proxy or `mitmproxy`), or
   - look for a newer pi-ai release that exposes a Console-aware
     helper, or
   - check Anthropic's developer docs.
2. **Mint response shape.** Spec tolerates both `{ raw_key }` and
   `{ key }` and bails loudly otherwise. The spec error message
   includes the raw response body so a wrong guess surfaces clearly.

These are the only items in the spec that aren't already verified
against the existing pi-ai source under `node_modules/`.

## Testing

- **Sidecar unit** — `sidecar/test/oauth-console.test.ts`. Mock
  `loginAnthropic` (return canned creds) and `fetch` (return a canned
  `{ raw_key: "sk-ant-api03-test" }`); assert
  `auth.anthropic.console.start` returns `{ apiKey }`. Add a second
  case where `fetch` returns 4xx with a body and assert the dispatcher
  errors with the body included.
- **Sidecar integration** — skipped. The real OAuth dance can't run
  in CI.
- **Mac** — extend `SidecarIntegrationTests` with a stubbed-RPC test
  that verifies `signInWithAnthropicConsole()` writes to Keychain and
  adds a `ProviderRecord` of the expected shape.
- **Manual smoke test before merge** — one end-to-end run against a
  real Anthropic Console account. This is the only path that
  validates the two known unknowns; CI cannot. Document the result
  (works / response shape) in the PR description.

## Out of scope

- Refreshing or rotating the minted key (user re-runs sign-in if
  needed).
- Listing or revoking minted keys from inside Multiharness (do that
  in console.anthropic.com).
- Telling the user *how* their account is being billed within the app
  beyond the provider name. The provider name is the entire
  disambiguation surface.

## Files touched (estimate)

- `sidecar/src/oauthStore.ts` — add ~40 lines
- `sidecar/src/methods.ts` — add ~10 lines
- `sidecar/test/oauth-console.test.ts` — new, ~80 lines
- `Sources/Multiharness/AppStore.swift` — add ~30 lines, refactor
  `openAnthropicAuthURL` for event-name reuse
- `Sources/MultiharnessClient/Models/Models.swift` — add ~10 lines
  (new preset + marker field)
- `Sources/Multiharness/.../AddProviderSheet.swift` (or wherever the
  preset sheet lives) — branch on `requiresConsoleSignIn`, ~10 lines
- `Tests/.../SidecarIntegrationTests.swift` — add ~30 lines

No schema migration. No iOS changes. No new dependencies.

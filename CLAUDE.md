# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Multiharness — a local AI coding harness for macOS, modeled after conductor.build. It runs multiple coding agents in parallel, each isolated in its own git worktree, and lets the user manage them through a native SwiftUI Mac app. An iOS companion app pairs with the Mac over LAN/Tailscale to drive the same agents remotely.

The product has three independently buildable components:

- **`sidecar/`** — a Bun + TypeScript WebSocket server that hosts [`@mariozechner/pi-agent-core`](https://www.npmjs.com/package/@mariozechner/pi-agent-core) agents, exposes a JSON-RPC-ish control API, owns the LLM provider abstraction, and persists per-workspace events. Compiles to a single `multiharness-sidecar` binary that the Mac app bundles in `Multiharness.app/Contents/Resources/`.
- **Mac app** — a SwiftUI executable target (`Sources/Multiharness/`) backed by two libraries: `MultiharnessClient` (portable across macOS + iOS, in `Sources/MultiharnessClient/`) and `MultiharnessCore` (macOS-only, in `Sources/MultiharnessCore/`). The app spawns the sidecar at launch and talks to it over a WebSocket on `127.0.0.1`.
- **iOS app** — `ios/` contains a SwiftUI iOS app generated from `ios/project.yml` via `xcodegen`. It depends on the same `MultiharnessClient` package and connects to the Mac's sidecar over LAN/Tailscale.

## Common commands

```bash
# Sidecar (Bun + TypeScript) — run from sidecar/
bun install
bun run typecheck                # tsc --noEmit
bun test                         # Bun's built-in test runner; tests live in sidecar/test/
bun test test/rpc.test.ts        # single test file
bun run dev                      # bun run src/index.ts (needs MULTIHARNESS_PORT or _SOCKET env)

# Sidecar binary — compiles to a standalone single-file executable
bash sidecar/scripts/build.sh    # → sidecar/dist/multiharness-sidecar

# Mac Swift package + executable — run from project root
swift build                      # debug build, no app bundle
swift test                       # 5 XCTest tests (PersistenceTests, SidecarIntegrationTests)

# Mac .app bundle (always run before launching the app interactively)
bash scripts/build-app.sh        # release build; CONFIG=debug for debug
                                 # outputs dist/Multiharness.app, signs with first
                                 # available identity (Apple Development > Developer ID >
                                 # "Multiharness Dev" self-signed > ad-hoc), applies
                                 # JIT/library-validation entitlements to the sidecar
                                 # via scripts/sidecar.entitlements (required — Bun
                                 # JITs and dies under hardened runtime without them)

# Mac code-signing setup (one-time, only if no Apple Dev cert is present)
bash scripts/setup-codesign.sh   # creates a "Multiharness Dev" self-signed cert in
                                 # the user's login keychain so cdhash-keyed Keychain
                                 # ACLs and TCC grants survive rebuilds

# iOS — always run from project root
bash scripts/build-ios.sh        # xcodegen generate + xcodebuild for iOS Simulator
MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh
                                 # also boots a sim, installs, and launches the app

# Reset Xcode IDE state if it shows "Missing package product 'MultiharnessClient'"
MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh
                                 # nukes DerivedData + workspace caches, then rebuilds
```

After any iOS source change, run `bash scripts/build-ios.sh`. Adding/removing iOS files (not just edits) requires the script's xcodegen step to refresh `MultiharnessIOS.xcodeproj`.

## Architecture

### Sidecar wire protocol

WebSocket frames carry UTF-8 JSON. JSON-RPC-ish:

```jsonc
// client → sidecar
{ "id": "req-1", "method": "agent.prompt", "params": { ... } }
// sidecar → client (response)
{ "id": "req-1", "result": { ... } }
{ "id": "req-1", "error": { "code": "...", "message": "..." } }
// sidecar → client (server-pushed event, no id)
{ "event": "message_update", "params": { "workspaceId": "...", ... } }
```

Methods are routed by `Dispatcher` in `sidecar/src/dispatcher.ts`; `methods.ts` registers them. Three top-level concerns there:

- **Agent lifecycle:** `agent.create`, `agent.prompt`, `agent.continue`, `agent.abort`, `agent.dispose`, `agent.list`. `AgentRegistry` keeps a `Map<workspaceId, AgentSession>`. Each `AgentSession` owns a `pi-agent-core` `Agent` instance, a tool list scoped to the worktree, and an append-only JSONL writer for that workspace's `messages.jsonl`.
- **Read-only views:** `remote.workspaces`, `remote.history`, `models.list`, `health.ping`. Served directly by the sidecar via `DataReader` (which reads the Mac's SQLite + JSONL files).
- **Mac-only operations** (relay): `workspace.create`, `project.scan`, `project.create`, `models.listForProvider`, `auth.anthropic.start`, `auth.openai.start`. These can't be done in the sidecar (need git, SQLite writes, NSOpenPanel, etc.) so they go through the `Relay` (`sidecar/src/relay.ts`). The Mac claims the relay role at startup via `client.register({ role: "handler" })`; subsequent relayed methods are forwarded to it as `relay_request` events, and it answers via `relay.respond({ relayId, result|error })`. Relay calls time out at 30s.

### Provider abstraction

`sidecar/src/providers.ts` defines `ProviderConfig` as a tagged union of five kinds:

- `pi-known` — delegates to pi-ai's curated registry (OpenRouter, OpenAI, Anthropic, OpenCode Zen + Go, DeepSeek, Mistral, Groq, etc.). Get correct baseUrl/headers/cost for free.
- `openai-compatible` — fully manual config for any OpenAI-compatible endpoint (LM Studio, Ollama, vLLM, custom proxies).
- `anthropic` — fully manual config for Anthropic-compatible endpoints.
- `anthropic-oauth` — Claude Pro/Max OAuth. Sidecar's `oauthStore.ts` persists refresh+access tokens at `<dataDir>/oauth/anthropic.json` (mode 0600) and refreshes ~5 min before expiry.
- `openai-codex-oauth` — ChatGPT Plus/Pro OAuth, same pattern as anthropic-oauth.

For OAuth providers the access token is resolved at request time by an async `getApiKey` callback on the `Agent` — refresh-on-demand happens transparently.

Provider API keys for non-OAuth providers live in the **Mac's macOS Keychain** under service `com.multiharness.providers`. The Mac builds the wire-level `providerConfig` (resolving the key from Keychain) when calling `agent.create`. iOS never sees keys.

### Mac persistence

`~/Library/Application Support/Multiharness/`
- `state.db` — SQLite. Tables: `projects`, `workspaces`, `providers`, `settings`. Schema migrations live in `Sources/MultiharnessCore/Persistence/Migrations.swift`; the migration list is append-only.
- `workspaces/<workspace_id>/messages.jsonl` — append-only event log per workspace. The Mac UI rehydrates conversation history from this file on `AgentStore.init`.
- `oauth/<provider>.json` — sidecar's OAuth credential store.
- `sock/control.sock` — kept available for a future Unix-socket transport (Phase 1 actually uses TCP loopback).

Worktrees live at `~/.multiharness/workspaces/<project_slug>/<workspace_slug>/` (note the dot — hidden in Finder).

### Sidecar lifecycle

`SidecarManager` (Mac) spawns the sidecar binary, watches stderr for the literal `READY` line plus the `info listening {"port":N}` log to learn the bound port, and signals readiness via a `PortWaiter` actor + continuation. On any non-explicit exit (`Process.terminationHandler`), it auto-restarts with capped exponential backoff (1, 2, 4, ..., 30s).

The sidecar emits a 2-second heartbeat (`heartbeat` log line, warn level) with RSS/heap/external memory and uptime, plus per-RPC `dispatch`/`dispatched` lines — useful for crash forensics. It also has signal handlers for SIGTERM/INT/ABRT/PIPE/SEGV (logs a breadcrumb) and `uncaughtException` / `unhandledRejection` handlers (log + survive). SIGKILL bypasses these — if it happens, the absence of any final breadcrumb is itself the signal (usually OOM).

### Remote access (iOS pairing)

When **Settings → Remote access** is toggled on:

- `RemoteAccess` (`Sources/MultiharnessCore/Sidecar/RemoteAccess.swift`) generates a 24-byte token, stores it in macOS Keychain (account `remote-access-token`), and pins a port (`remote_access.stable_port`) so iPhone pairings survive restarts.
- The sidecar relaunches with `MULTIHARNESS_BIND=0.0.0.0` + `MULTIHARNESS_AUTH_TOKEN=<token>`. Every WebSocket upgrade then requires `Authorization: Bearer <token>`.
- `RemoteAccess` advertises `_multiharness._tcp.` via `NetService` (registration-only — doesn't bind a socket; avoids conflict with the sidecar's listener).
- The pairing string is `mh://<host>:<port>?token=<token>&name=<host-name>`. The Settings panel renders it as a QR (`CIQRCodeGenerator`) plus copyable text. The user picks which interface to advertise; Tailscale (`utun*` with `100.64.0.0/10` IP) is the default if present.
- `BookmarkScope` captures security-scoped bookmarks for project repo URLs at `NSOpenPanel` time and reactivates them on Mac launch — required so the agent can read files in TCC-protected directories (Documents/Desktop) without re-prompting.

There is **no TLS** — token auth on plaintext WS over LAN/Tailscale. Tailscale's E2E encryption is what makes this acceptable for cross-network use.

### iOS pairing model

`PairingStore` keeps a list of paired Macs (Keychain account `pairings.v2`) plus an active id. Adding a pairing replaces an existing entry by `host:port`. `RootView` shows a **Mac switcher** sheet (paired Macs with active indicator, swipe-to-forget) and an **Add another Mac** sheet (the existing PairingView reused).

iOS-initiated mutations (`workspace.create`, `project.create`, `models.listForProvider`) flow through the **relay**: iOS calls a method on the sidecar, sidecar forwards to the Mac handler (`Sources/Multiharness/RemoteHandlers.swift`) as a `relay_request` event, Mac executes locally, response travels back through `relay.respond`.

## Phasing & deviations

The project shipped Phase 1 (Mac harness) + Phase 3 (network exposure) + Phase 4 (iOS) collapsed. Two deliberate spec deviations:

- **TCP loopback** instead of Unix domain socket for the control transport — `URLSessionWebSocketTask` doesn't speak Unix sockets, and the threat model is single-user/local-machine. The pinned port survives Mac restarts.
- **Embedded terminal** and **full diff hunk view** are deferred. The Mac's Inspector shows changed/untracked file lists and a raw text preview of the selected file.

See `docs/superpowers/specs/2026-04-28-multiharness-phase-1-design.md` and `docs/superpowers/plans/2026-04-28-sidecar.md` for the formal design. The plan is the authoritative reference for the sidecar's task breakdown.

## Common pitfalls

- **Bun's JIT + hardened runtime.** The sidecar binary must be signed with `--options runtime` AND have the JIT entitlements in `scripts/sidecar.entitlements` (`allow-jit`, `allow-unsigned-executable-memory`, `disable-library-validation`). Without them, AMFI/hardened runtime kills the sidecar the moment a remote client connects. `build-app.sh` already does this; if you re-sign manually, re-apply the entitlements.
- **Ad-hoc signing** (when no Apple Dev cert is present) gives every rebuild a fresh `cdhash`, busting Keychain ACLs and TCC grants. `setup-codesign.sh` exists to mitigate this for users without an Apple Developer account.
- **iOS package resolution drift.** If Xcode shows "Missing package product 'MultiharnessClient'", run `MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh` and reopen the project. The CLI builds via `xcodebuild -resolvePackageDependencies` are reliable; the IDE's resolver is occasionally finicky with `..`-relative local packages.
- **Empty assistant cards.** `AgentStore.handleEvent` lazy-creates an assistant turn on the first `text_delta` (not on `message_start`), so tool-call-only assistant messages don't produce empty cards. Preserve this behavior when refactoring the event handling.

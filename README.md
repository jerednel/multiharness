# Multiharness

A local AI coding harness for macOS. Run multiple coding agents in parallel, each isolated in its own git worktree, all managed from a native SwiftUI Mac app — with an iOS companion app for driving the same agents remotely over LAN or Tailscale.

Think [conductor.build](https://conductor.build), but local-first, open, and pluggable across providers (OpenAI, Anthropic, OpenRouter, LM Studio, Ollama, DeepSeek, Groq, and anything OpenAI- or Anthropic-compatible).

> [!NOTE]
> macOS 14 (Sonoma) or later. Apple Silicon recommended. iOS companion requires iOS 17+.

---

## What's in the box

| Component | What it is | Where it lives |
|---|---|---|
| **Mac app** | Native SwiftUI app — the thing you actually use. | `Sources/Multiharness/` (executable), `Sources/MultiharnessCore/` (macOS-only lib), `Sources/MultiharnessClient/` (portable lib) |
| **Sidecar** | Bun + TypeScript WebSocket server that hosts the agents. Bundled inside `Multiharness.app`. | `sidecar/` |
| **iOS app** | SwiftUI companion that pairs with your Mac. | `ios/` |

The Mac app spawns the sidecar binary at launch and talks to it over `127.0.0.1`. The sidecar embeds [`pi-agent-core`](https://www.npmjs.com/package/@mariozechner/pi-agent-core), which provides the agent loop and the unified provider abstraction.

---

## Quick start (macOS app)

### Prerequisites

You need these installed:

- **Xcode 15+** (or at least the Command Line Tools) — for `swift`, `xcodebuild`, and `codesign`.
- **[Bun](https://bun.sh) ≥ 1.1** — the sidecar runtime. Install with `curl -fsSL https://bun.sh/install | bash`.
- **Git** — already on every Mac.
- *(Optional but recommended)* an **Apple Developer account** so your builds can be signed with a real "Apple Development" certificate. Without one, see the self-signed flow below.

### One-time setup

```bash
# 1. Clone and enter the repo
git clone <this-repo-url> multiharness
cd multiharness

# 2. Install sidecar dependencies
cd sidecar && bun install && cd ..

# 3. (Only if you don't have an Apple Developer cert) create a stable
#    self-signed code-signing identity. Without this, every rebuild gets
#    a new cdhash and your Keychain / TCC grants will be reset constantly.
bash scripts/setup-codesign.sh
```

### Build and run

```bash
# Build the full .app bundle (release config by default).
# This:
#   - Compiles the sidecar to a single-file binary
#   - Builds the Swift package
#   - Wires both into dist/Multiharness.app
#   - Signs everything (sidecar gets JIT entitlements — Bun needs JIT)
bash scripts/build-app.sh

# Build the macOS DMG release
bash scripts/build-dmg.sh

# Launch it
open dist/Multiharness.app
```

For a faster dev cycle, debug builds work too:

```bash
CONFIG=debug bash scripts/build-app.sh
```

That's it. The first time you launch, the app will:

1. Spawn the bundled sidecar on a loopback port.
2. Drop persistent state into `~/Library/Application Support/Multiharness/` (SQLite + JSONL event logs).
3. Create worktrees on demand at `~/.multiharness/workspaces/<project>/<workspace>/`.

### Adding a provider

Open **Settings → Providers** in the app. You have three options for each provider:

- **Pi-known** — pick from a curated registry (OpenAI, Anthropic, OpenRouter, DeepSeek, Mistral, Groq, OpenCode Zen, etc.) and just paste an API key. Base URLs, model lists, and pricing are handled for you.
- **OpenAI-compatible** — manual config for LM Studio, Ollama, vLLM, custom proxies, anything that speaks OpenAI's API.
- **Anthropic-compatible** — manual config for Anthropic-compatible endpoints.
- **OAuth** — Claude Pro/Max and ChatGPT Plus/Pro both work via OAuth (no API key required).

API keys live in **macOS Keychain** under the service `com.multiharness.providers`. They never touch disk in plaintext and the iOS app never sees them — it asks the Mac to do anything that needs a key.

---

## iOS companion (optional)

Pair your phone with your Mac and drive the same agents from anywhere on your LAN — or anywhere on the internet if you have [Tailscale](https://tailscale.com).

### Build the iOS app

```bash
# First time only — install xcodegen
brew install xcodegen

# Build for the iOS Simulator
bash scripts/build-ios.sh

# Or build + boot a simulator + install + launch in one shot
MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh
```

To run on a real device, open `ios/MultiharnessIOS.xcodeproj` in Xcode after running `build-ios.sh` once, then pick your device and hit ⌘R.

> [!TIP]
> If Xcode complains **"Missing package product 'MultiharnessClient'"**, nuke the resolver caches and try again:
> ```bash
> MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh
> ```

### Pairing

1. In the Mac app: **Settings → Remote access → Enable**. Pick the network interface to advertise on (Tailscale `utun*` is the default if present).
2. The Mac shows a QR code containing `mh://<host>:<port>?token=<token>&name=<name>`.
3. Scan it from the iOS app, or paste the URL. Done.

The pairing token is stored in the Mac's Keychain and the iOS app's Keychain. Plaintext WebSocket + bearer token; if you're going off-LAN, run it over Tailscale and let WireGuard handle the encryption.

---

## Development

### Repo layout

```
.
├── Package.swift               # Swift package — Mac + iOS share code via MultiharnessClient
├── Sources/
│   ├── Multiharness/           # macOS app executable target
│   ├── MultiharnessCore/       # macOS-only: SQLite, worktrees, sidecar lifecycle, Bonjour
│   └── MultiharnessClient/     # Portable across macOS + iOS: models, WS client, Keychain
├── Tests/MultiharnessCoreTests/
├── sidecar/                    # Bun + TypeScript server (compiled into the .app)
│   ├── src/                    # dispatcher, methods, providers, agent registry, oauth
│   ├── test/                   # bun test
│   └── scripts/build.sh        # Bun --compile → single-file binary
├── ios/                        # SwiftUI iOS app, generated from project.yml via xcodegen
├── scripts/                    # build-app.sh, build-ios.sh, setup-codesign.sh, …
├── docs/superpowers/           # Design specs and implementation plans
├── assets/                     # App icon
└── CLAUDE.md                   # Architecture deep-dive for AI agents
```

### Common commands

```bash
# ─── Sidecar (run from sidecar/) ──────────────────────────────────────
bun install
bun run typecheck             # tsc --noEmit
bun test                      # all tests
bun test test/rpc.test.ts     # a single test file
bun run dev                   # run sidecar standalone (set MULTIHARNESS_PORT)

# ─── Swift package (run from repo root) ───────────────────────────────
swift build                   # debug build, no app bundle
swift test                    # XCTest tests

# ─── Full Mac app bundle ──────────────────────────────────────────────
bash scripts/build-app.sh                     # release
CONFIG=debug bash scripts/build-app.sh        # debug

# ─── iOS app ──────────────────────────────────────────────────────────
bash scripts/build-ios.sh                     # build for simulator
MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh   # build + boot + install + launch
MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh  # nuke caches first
```

### Iteration workflow

- **Editing Mac Swift code:** `swift build` for a quick syntax/type check, then `bash scripts/build-app.sh` + `open dist/Multiharness.app` to actually run.
- **Editing sidecar TypeScript:** `bun run typecheck` + `bun test` from `sidecar/`. The next `build-app.sh` will pick up your changes.
- **Editing iOS Swift code:** `bash scripts/build-ios.sh` after every change. Adding or removing files (not just edits) needs the same command — it re-runs `xcodegen` to refresh the `.xcodeproj`.

---

## For AI agents working in this repo

If you're an AI coding agent (Claude Code, Cursor, etc.) checking out this repo to make changes, **read [`CLAUDE.md`](./CLAUDE.md) first.** It's the architecture-level briefing: wire protocol, provider abstraction, persistence layout, sidecar lifecycle, iOS pairing model, and a list of well-known pitfalls.

Quick orientation:

1. **Where to start reading code:**
   - Sidecar entry: `sidecar/src/index.ts` → `dispatcher.ts` → `methods.ts`.
   - Mac entry: `Sources/Multiharness/App.swift`. State lives in `Sources/MultiharnessCore/`.
   - iOS entry: `ios/Sources/MultiharnessIOSApp.swift`.

2. **Authoritative design docs** are under `docs/superpowers/`:
   - `specs/` — design documents per feature (the "what" and "why").
   - `plans/` — implementation breakdowns per feature (the "how", task-by-task).
   - The foundational doc is `specs/2026-04-28-multiharness-phase-1-design.md`.

3. **Verification commands** (run these before claiming a change works):

   | You changed | Run |
   |---|---|
   | Sidecar TS | `cd sidecar && bun run typecheck && bun test` |
   | Mac Swift | `swift build && swift test` |
   | Mac app behavior end-to-end | `bash scripts/build-app.sh` and launch `dist/Multiharness.app` |
   | iOS Swift | `bash scripts/build-ios.sh` |
   | iOS files added/removed | `bash scripts/build-ios.sh` (refreshes Xcode project from `project.yml`) |

4. **Footguns to know about** (full list in `CLAUDE.md` → *Common pitfalls*):
   - The sidecar **must** be signed with `--options runtime` + the JIT entitlements in `scripts/sidecar.entitlements`. Bun uses JavaScriptCore's JIT and hardened runtime will kill it otherwise. `build-app.sh` handles this; if you re-sign manually, re-apply the entitlements.
   - Ad-hoc signing changes the binary's `cdhash` on every rebuild, which breaks Keychain ACL caching and TCC grants. Run `scripts/setup-codesign.sh` once to avoid this.
   - If Xcode says **"Missing package product 'MultiharnessClient'"**, run with `MULTIHARNESS_RESET_XCODE_CACHES=1`. The CLI build is reliable; the IDE's resolver is occasionally flaky with `..`-relative local packages.
   - `AgentStore.handleEvent` lazy-creates assistant turns on the first `text_delta`, not on `message_start`. This intentionally avoids empty cards for tool-call-only assistant messages — preserve this behavior when refactoring the event handling.

5. **Don't add files outside the documented structure** without checking the relevant spec under `docs/superpowers/specs/` — the layout matters for `xcodegen`, SwiftPM, and the sidecar's bundling.

---

## Troubleshooting

<details>
<summary><strong>The app launches but immediately disconnects from the sidecar</strong></summary>

This is almost always a code-signing problem. Symptoms in `Console.app` will include `AMFI` killing the sidecar process.

Fix:
```bash
bash scripts/setup-codesign.sh   # if you haven't already
bash scripts/build-app.sh        # rebuild — sign with stable identity + JIT entitlements
```
</details>

<details>
<summary><strong>"Multiharness.app" is damaged and can't be opened</strong></summary>

Gatekeeper quarantine on the ad-hoc-signed binary. Either:
```bash
xattr -dr com.apple.quarantine dist/Multiharness.app
```
or run `scripts/setup-codesign.sh` and rebuild.
</details>

<details>
<summary><strong>iOS app can't see my Mac on the network</strong></summary>

- Make sure **Settings → Remote access** is toggled on in the Mac app.
- iOS needs the **Local Network** permission — accept the system prompt on first launch, or enable it in iOS Settings → Multiharness.
- If you're using Tailscale, both devices must be logged in to the same tailnet and the Tailscale interface must be selected in the Mac app's interface picker.
</details>

<details>
<summary><strong>Xcode shows "Missing package product 'MultiharnessClient'"</strong></summary>

```bash
MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh
```
Then close and reopen the project in Xcode.
</details>

---

## License

TBD.

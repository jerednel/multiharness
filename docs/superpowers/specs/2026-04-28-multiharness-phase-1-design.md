# Multiharness — Phase 1 Design

**Date:** 2026-04-28
**Status:** Approved
**Scope:** Phase 1 of a phased project. Phases 2–4 are sketched at the end; only Phase 1 is specced here.

## Product summary

Multiharness is a local AI coding harness for macOS, modeled after conductor.build. It runs multiple coding agents in parallel, each isolated in its own git worktree, and lets the user manage them through a native SwiftUI Mac app. Agents are powered by [pi-mono](https://github.com/badlogic/pi-mono)'s `pi-agent-core` and `pi-ai`, which provide a unified provider abstraction over OpenAI-compatible (incl. LM Studio), Anthropic, and other endpoints.

A future iOS companion app (Phase 4) will act as a thin remote control over the same local control API the Mac app's UI uses internally.

## Phase 1 goals

Phase 1 collapses what was originally Phases 1+2 of the brainstorm: ship a multi-workspace harness with full agent UX, not just a single-agent MVP.

In scope:

- Native SwiftUI Mac app (`Multiharness.app`)
- Multi-project, multi-workspace UX with lifecycle state buckets matching the conductor.build screenshot (`backlog`, `in_progress`, `in_review`, `done`, `cancelled`)
- Per-workspace git worktree management
- Embedded Bun-based sidecar that hosts `pi-agent-core` and exposes a WebSocket-over-Unix-socket control API
- Provider abstraction supporting OpenAI-compatible endpoints (incl. LM Studio), Anthropic, and "any custom OpenAI-compatible URL". Keys live in macOS Keychain.
- Per-workspace agent view: conversation thread with inline tool-call cards, message composer
- Per-workspace file panel with `All files` and `Changes` tabs (`Changes` shows diff vs base branch)
- Per-workspace embedded terminal (PTY) with `cwd` = worktree

Out of scope (deferred):

- iOS companion app (Phase 4)
- Network exposure of the control API + pairing/auth (Phase 3)
- "Setup script" runner per project (Phase 2)
- "Checks" tab / CI integration (Phase 2)
- Multiple agents per workspace
- Cloud sync, session sharing, telemetry

## Architecture

```
┌──────────────────────────────────────────────────────┐
│ Multiharness.app (SwiftUI)                           │
│                                                      │
│  ┌──────────────┐   ┌──────────────────────────┐     │
│  │  UI Layer    │   │  MultiharnessCore        │     │
│  │              │   │                          │     │
│  │  Views       │◄─►│  Stores (Observable)     │     │
│  │  ViewModels  │   │  PersistenceService      │     │
│  │  SwiftTerm   │   │  WorktreeService         │     │
│  └──────────────┘   │  KeychainService         │     │
│                     │  SidecarManager          │     │
│                     │  ControlClient (WS)      │     │
│                     └────────────┬─────────────┘     │
└──────────────────────────────────┼───────────────────┘
                                   │
                       Unix domain socket
                       (WebSocket frames, JSON)
                                   │
┌──────────────────────────────────┼───────────────────┐
│ multiharness-sidecar (Bun)       ▼                   │
│                                                      │
│  ┌──────────────────────────────────────────────┐    │
│  │  WebSocket server                            │    │
│  │  Method dispatcher (JSON-RPC-ish)            │    │
│  │  Event broadcaster                           │    │
│  └──────────────────────────────────────────────┘    │
│                       │                              │
│  ┌────────────────────┴───────────────────────────┐  │
│  │  AgentRegistry: workspaceId → AgentSession     │  │
│  │                                                │  │
│  │  AgentSession {                                │  │
│  │    pi-agent-core Agent instance                │  │
│  │    tool implementations (scoped to worktree)  │  │
│  │    pi-ai provider/model config                 │  │
│  │  }                                             │  │
│  └────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────┘
```

The Mac app launches the sidecar as a child process at startup and waits for the socket to become ready. The sidecar exits with the app (parent-pid watchdog).

## Data model

### SQLite (`~/Library/Application Support/Multiharness/state.db`)

```
projects (
  id              TEXT PRIMARY KEY,        -- UUID
  name            TEXT NOT NULL,
  slug            TEXT NOT NULL UNIQUE,
  repo_path       TEXT NOT NULL,
  default_base_branch TEXT NOT NULL DEFAULT 'main',
  default_provider_id TEXT,
  default_model_id    TEXT,
  created_at      INTEGER NOT NULL
)

workspaces (
  id              TEXT PRIMARY KEY,
  project_id      TEXT NOT NULL REFERENCES projects(id),
  name            TEXT NOT NULL,
  slug            TEXT NOT NULL,
  branch_name     TEXT NOT NULL,
  base_branch     TEXT NOT NULL,
  worktree_path   TEXT NOT NULL,
  lifecycle_state TEXT NOT NULL,           -- backlog|in_progress|in_review|done|cancelled
  provider_id     TEXT NOT NULL,
  model_id        TEXT NOT NULL,
  created_at      INTEGER NOT NULL,
  archived_at     INTEGER
)

providers (
  id                  TEXT PRIMARY KEY,
  name                TEXT NOT NULL,        -- user-visible label
  kind                TEXT NOT NULL,        -- 'anthropic' | 'openai-compatible'
  base_url            TEXT NOT NULL,
  default_model_id    TEXT,
  keychain_account    TEXT,                 -- null => no key (e.g. LM Studio)
  created_at          INTEGER NOT NULL
)

settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
)
```

### JSONL message log

`~/Library/Application Support/Multiharness/workspaces/<workspace_id>/messages.jsonl`

One JSON object per line. Append-only. Schema mirrors pi-agent-core's `AgentMessage`:

```jsonc
{ "seq": 0, "ts": 1730000000, "kind": "user",        "content": "...prompt..." }
{ "seq": 1, "ts": 1730000001, "kind": "assistant",   "content": [...], "toolCalls": [...] }
{ "seq": 2, "ts": 1730000002, "kind": "tool_result", "toolCallId": "...", "result": ... }
```

Reads are streaming/tail-based; the sidebar never scans these files (metadata stays in SQLite).

### Keychain

Provider API keys are stored in the macOS Keychain (service: `com.multiharness.providers`, account: `<provider_id>`). The DB stores only `keychain_account`.

## Wire protocol

WebSocket frames; each frame is a UTF-8 JSON object. JSON-RPC-ish shape.

**Request:**
```json
{ "id": "req-123", "method": "agent.prompt", "params": { ... } }
```

**Response:**
```json
{ "id": "req-123", "result": { ... } }
{ "id": "req-123", "error": { "code": "...", "message": "..." } }
```

**Server-pushed event** (no `id`, has `event`):
```json
{ "event": "message_update", "params": { "workspaceId": "...", "delta": "..." } }
```

### Methods (Phase 1)

| Method | Description |
|---|---|
| `agent.create` | `{ workspaceId, providerConfig, modelId, systemPrompt, tools[] }` → opens an `AgentSession` |
| `agent.prompt` | `{ workspaceId, message }` → starts a turn; events stream back |
| `agent.continue` | `{ workspaceId }` → resume after error |
| `agent.abort` | `{ workspaceId }` → abort current turn |
| `agent.dispose` | `{ workspaceId }` → drop session from registry |
| `agent.list` | `{}` → list active workspace IDs in registry |
| `health.ping` | `{}` → `{ pong: true, version }` |

### Events

Re-exposes pi-agent-core's event stream verbatim, namespaced by `workspaceId`:

`agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_update`, `tool_execution_end`.

The sidecar also persists each meaningful event to the workspace's `messages.jsonl` so the Mac app can rehydrate history without keeping the agent live.

## Agent runtime (sidecar)

### Tools

The agent's tool surface mirrors Claude Code's standard set. All paths are validated to remain inside the workspace's `worktree_path`; absolute paths outside are rejected.

| Tool | Behavior |
|---|---|
| `read_file(path)` | Read UTF-8 contents |
| `write_file(path, content)` | Overwrite or create |
| `edit_file(path, old_string, new_string)` | Exact-match string replace |
| `glob(pattern, path?)` | Glob inside worktree |
| `grep(pattern, path?, options?)` | ripgrep-style search |
| `bash(command, working_dir?, timeout?)` | Spawn `/bin/zsh -c <command>`, `cwd` defaults to worktree, timeout default 120s |
| `list_dir(path)` | Directory listing |

Implementation lives in `sidecar/src/tools/`. We borrow logic from `@mariozechner/pi-coding-agent` where it exposes reusable functions; otherwise we implement directly on `pi-agent-core`'s `AgentTool` interface.

### Provider mapping

`pi-ai` already supports every endpoint we care about. Multiharness's `providers` table rows map to `pi-ai` configurations as follows:

- `kind = 'anthropic'`: `getModel('anthropic', model_id)` with `apiKey` from Keychain, optional `baseUrl` override.
- `kind = 'openai-compatible'`: `pi-ai`'s "any OpenAI-compatible API" pathway with the configured `base_url` (LM Studio, Ollama, vLLM, OpenAI itself, etc.) and `apiKey` from Keychain (may be empty for local).

A provider with `keychain_account = NULL` and `base_url = http://localhost:1234/v1` is seeded as "LM Studio (local)" on first launch.

## Worktree management (Mac app)

`WorktreeService` wraps `git` shelling out from Swift.

**Create workspace** (called when user submits the New Workspace dialog):

```
git -C <repo_path> fetch origin                      # best-effort, non-fatal
git -C <repo_path> worktree add -b <branch_name> <worktree_path> <base_branch>
```

**Status polling** (debounced; triggered by FSEvents on `worktree_path`):

```
git -C <worktree_path> status --porcelain
git -C <worktree_path> diff --stat <base_branch>...HEAD
```

**Diff for `Changes` tab**:

```
git -C <worktree_path> diff <base_branch>...HEAD -- <file>
```

**Archive workspace**: keep worktree on disk by default. Optional "Remove worktree" menu item runs `git worktree remove <worktree_path>` and updates `archived_at`.

## Mac app — UI shell

`NavigationSplitView` with three columns:

1. **Sidebar (left)** — collapsible project switcher at top, then workspaces grouped by lifecycle state (sections in screenshot order: `In progress`, `In review`, `Done`, `Backlog`, `Cancelled`). Right-click context menu: change state, rename, archive, remove worktree, copy branch name.

2. **Workspace pane (middle)** — top banner (workspace name + branch info, base branch, lifecycle pill). Below: scrolling conversation thread. Bottom: message composer (multiline, model picker dropdown, send button). Inline tool calls render as expandable cards with input args and result preview.

3. **Inspector (right)** — vertical split: top half is `All files` / `Changes` tab view; bottom half is `Terminal` (PTY rooted at the worktree). Tabs in the file panel are local to this column. Inspector is collapsible.

### View-model layer

A small set of `@Observable` stores in `MultiharnessCore`:

- `AppStore` — current project, providers, settings
- `WorkspaceStore` — list of workspaces for current project, lifecycle grouping
- `AgentStore` (per workspace) — message log, current turn state, streaming text buffer, tool-call states

`AgentStore` subscribes to `ControlClient` events filtered by `workspaceId` and applies them to its in-memory log. New messages are also appended to the JSONL file by the sidecar; the Mac app *reads* JSONL only when rehydrating an inactive workspace.

### Terminal

We use [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) for the PTY-backed terminal widget. One shell session per workspace, lazily started when the user opens the terminal tab. `TERM=xterm-256color`, `cwd` = `worktree_path`, env inherits user shell.

## Sidecar bundling and lifecycle

The sidecar is a single Bun binary (`multiharness-sidecar`) built from `sidecar/` at app build time. The binary is copied into `Multiharness.app/Contents/Resources/`.

`SidecarManager` (Swift):

- Locates the bundled binary via `Bundle.main.url(forResource:)`
- Computes socket path: `~/Library/Application Support/Multiharness/sock/control.sock`
- Removes any stale socket before launch
- Spawns the binary with env `MULTIHARNESS_SOCKET=<path>` and `MULTIHARNESS_DATA_DIR=<...>`
- Watches stderr for the line `READY` before signaling the UI it can connect
- Sends `health.ping` periodically; restarts the sidecar on crash (with backoff)
- Sends `SIGTERM` on app quit and waits up to 5s before `SIGKILL`

The sidecar itself uses a parent-pid watchdog (poll `getppid()` every 1s; exit if it changes to 1).

## Workspace creation flow

User clicks **+ New Workspace** in the sidebar:

1. Modal dialog asks for: `name` (required), `base_branch` (default = project default), `provider + model` (default = project default), `initial prompt` (optional).
2. App slugifies name → `slug`. Branch name = `<git-user>/<slug>` (matches the convention this branch already uses).
3. `WorktreeService.create(...)` runs `git worktree add`.
4. `PersistenceService` inserts the `Workspace` row with `lifecycle_state = 'in_progress'`.
5. `ControlClient.send("agent.create", ...)` opens an `AgentSession` in the sidecar.
6. If `initial_prompt` was provided, immediately `agent.prompt`.
7. UI navigates to the new workspace.

## Failure modes and behaviors

| Failure | Behavior |
|---|---|
| Sidecar fails to start | UI shows banner with stderr tail; retries with backoff; agent features disabled until reconnect |
| WebSocket disconnects mid-turn | UI shows reconnecting state; on reconnect, sidecar reports active workspaces; UI re-subscribes; in-flight turns may be lost (best-effort) |
| `git worktree add` fails | Modal stays open with stderr; nothing persisted |
| Provider returns auth error | Tool-call card and turn marked failed; user can retry via composer |
| Tool execution throws | Reported as `tool_execution_end` with error; agent decides whether to continue |
| Worktree path missing on disk | Workspace shown with warning badge; "Recreate worktree" action offered |

## Testing strategy

**Sidecar (vitest):**
- Unit tests for `AgentRegistry` lifecycle (create, dispose, isolation)
- Tool tests with a temp worktree directory
- Integration test against a mock pi-ai provider that returns scripted streams
- Path-escape test: `read_file('../etc/passwd')` rejected

**Mac app (XCTest / Swift Testing):**
- `WorktreeService` against a temp git repo fixture
- `PersistenceService` migrations + CRUD
- `ControlClient` against a mock WS server (echoes events)
- View-model tests for `AgentStore` event reduction

**End-to-end:**
- Smoke test: launch the app's headless mode, create project + workspace, send prompt to a deterministic mock provider via a fake `base_url`, assert messages appear in the JSONL log and SQLite reflects expected state.

## Project / module layout

```
multiharness/
├─ Multiharness.xcodeproj/
├─ Multiharness/                  # App target
│   ├─ MultiharnessApp.swift
│   └─ Resources/
│       └─ multiharness-sidecar   # bundled at build time
├─ Packages/
│   ├─ MultiharnessCore/          # Swift package
│   │   ├─ Sources/MultiharnessCore/
│   │   │   ├─ Models/
│   │   │   ├─ Persistence/
│   │   │   ├─ Worktree/
│   │   │   ├─ Sidecar/
│   │   │   ├─ Control/           # WS client
│   │   │   └─ Stores/
│   │   └─ Tests/MultiharnessCoreTests/
│   └─ MultiharnessUI/            # Swift package
│       ├─ Sources/MultiharnessUI/
│       │   ├─ Sidebar/
│       │   ├─ Workspace/
│       │   ├─ Inspector/
│       │   ├─ Terminal/
│       │   └─ Settings/
│       └─ Tests/MultiharnessUITests/
├─ sidecar/                       # Bun project
│   ├─ src/
│   │   ├─ server.ts
│   │   ├─ rpc.ts
│   │   ├─ agentRegistry.ts
│   │   ├─ providers.ts
│   │   └─ tools/
│   ├─ test/
│   ├─ package.json
│   └─ tsconfig.json
├─ scripts/
│   ├─ build-sidecar.sh           # bun build → single binary → copy into Resources/
│   └─ build-app.sh               # xcodebuild
└─ docs/
    └─ superpowers/specs/...
```

## Phasing (recap, for context only)

- **Phase 1 (this spec):** Mac harness with multi-workspace UX. Local only.
- **Phase 2:** Setup scripts, `Checks` tab, polish (drag-to-reorder lifecycle, search, project settings UI).
- **Phase 3:** Expose the WebSocket control API on local network with mDNS advertisement, pairing flow, token auth, TLS via self-signed cert pinned by the iOS app.
- **Phase 4:** Native SwiftUI iOS app — pairs with a Mac instance over LAN, renders a thin client of the control API.

## Open questions

None blocking Phase 1. The following will be resolved during implementation:

- Whether to import tool implementations from `@mariozechner/pi-coding-agent` directly or write our own thin layer on top of `@mariozechner/pi-agent-core`. Decided at the moment we build the sidecar's tool module.
- Exact WebSocket library on the Swift side. Default plan: `Network.framework` with manual frame handling (we own both ends, so we don't need full RFC 6455 — but a small dep like `Starscream` is acceptable if it slots in cleanly).

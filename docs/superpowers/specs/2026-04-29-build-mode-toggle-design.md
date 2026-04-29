# Build Mode Toggle — Design

**Date:** 2026-04-29
**Status:** Approved (vibe-coded sign-off, brainstorming round 1)
**Scope:** New per-workspace setting that informs the agent whether builds happen in this worktree or against the user's primary checkout. Inform-only via system-prompt context — no tool gating.

## Problem

Multiharness runs N parallel agents in N worktrees. Local builds (Xcode, dev server, etc.) are typically scoped to a single checkout — the user can only point Xcode at one worktree at a time. Agents in non-active worktrees that try to run `swift build` / `xcodebuild` / `npm test` waste cycles on builds the user can't observe and the agent can't iterate against.

This feature lets the user mark a worktree as `shadowed` so its agent knows builds happen elsewhere and won't waste cycles trying to run them. The active worktree stays in `primary` mode (today's default behavior).

A separate, larger feature (`reconcile-worktrees`) handles end-of-stream integration. This spec is independent of that work.

## User-facing model

Each workspace has a **build mode**:

- **This worktree** (`primary`) — agent has a full build/test feedback loop. Default.
- **Local main** (`shadowed`) — agent is told builds happen elsewhere. Agent should reason from the code and not run build commands.

Each project has a **default build mode** that pre-selects the workspace control. Users set the project default inline via a "Make default for this project" checkbox in the New Workspace sheet.

## Architecture

### Data model

Migration v3 (append-only, in `Sources/MultiharnessCore/Persistence/Migrations.swift`):

```sql
ALTER TABLE projects   ADD COLUMN default_build_mode TEXT;
ALTER TABLE workspaces ADD COLUMN build_mode         TEXT;
```

Both columns nullable. Stored values are the literal strings `"primary"` and `"shadowed"`. NULL means "inherit from the next layer up."

Resolution precedence at agent-session-creation time:

```
workspace.build_mode  →  project.default_build_mode  →  "primary"
```

Existing rows have NULL for both columns; they resolve to `"primary"` and behave exactly like today.

### Wire protocol

`workspace.create` (relayed Mac-side) gains one optional param:

```ts
{ projectId, name, providerId, modelId, baseBranch?, buildMode?, makeProjectDefault? }
```

`buildMode`: `"primary"` | `"shadowed"` | `undefined` (= inherit project default).
`makeProjectDefault`: boolean. If true, the Mac handler also writes `buildMode` to `projects.default_build_mode` for the same project.

The Mac handler resolves the effective mode via the precedence chain, persists the workspace row (storing NULL when the mode equals the project default — keeps inheritance live), optionally updates the project row, and returns the resolved mode in the response.

`agent.create` gains an optional `buildMode` param. The Mac is the source of truth: it resolves the mode and passes the resolved value when bootstrapping the agent session.

Invalid `buildMode` values are rejected with RPC error `invalid_build_mode`.

### System prompt assembly (sidecar)

Today the system prompt is hardcoded in `Sources/MultiharnessCore/Stores/AppStore.swift:50` and passed verbatim to the sidecar via `agent.create`. This spec moves prompt assembly into the sidecar's `AgentSession` so it owns the canonical text and can vary it by mode. The Mac stops passing a `systemPrompt` and instead passes only `buildMode`.

`AgentSession` builds the prompt as:

- **`primary`:** today's literal — *"You are a helpful coding agent operating inside a git worktree. Use the available tools to read and modify files."*
- **`shadowed`:** the same base, plus an addendum:
  > *"Builds and tests for this project are run by the user against a different checkout, not this worktree. Do not run build, test, or run commands (e.g. `swift build`, `xcodebuild`, `npm test`, `bun run dev`) — you will not get useful feedback from them. Reason carefully from the code; the user will verify."*

Both strings live as constants in `sidecar/src/agentSession.ts`. Fixed text in v1, not customizable per project.

No tool gating. The bash tool remains available; the agent is trusted to honor the prompt.

### Mac UI

`Sources/Multiharness/Views/Sheets.swift` — `NewWorkspaceSheet`:

- New segmented control labeled **Build target**: `This worktree` | `Local main`.
- Pre-selected from the project's `defaultBuildMode` (falling back to `This worktree` if the project hasn't set one).
- Below it, a checkbox: **Make default for this project** (pre-unchecked; enabled whenever the segmented control's current value differs from the project's currently-resolved default — treating a NULL `default_build_mode` as `"primary"`).

Submission sets `buildMode` and `makeProjectDefault` in the relayed `workspace.create` call.

No new project settings sheet. The inline checkbox is the only path to set the project default in v1; a dedicated settings sheet is out of scope (and is a likely natural home for this and `default_provider_id` in a follow-up).

### iOS UI

`ios/Sources/MultiharnessIOS/...` — the equivalent NewWorkspaceSheet view gets the same segmented control + checkbox. iOS calls the same relayed `workspace.create` method; no protocol divergence.

### `Project` and `Workspace` model structs

`Sources/MultiharnessClient/Models/Models.swift`:

- `Project` gets `defaultBuildMode: BuildMode?`.
- `Workspace` gets `buildMode: BuildMode?` (the stored value, may be NULL = inherit) and a computed `effectiveBuildMode: BuildMode` that walks the precedence chain.
- New `enum BuildMode: String, Codable { case primary, shadowed }`.

These structs are shared across Mac + iOS via the `MultiharnessClient` library.

## Error handling

- Invalid mode string at the relay handler → reject with `invalid_build_mode`.
- The UI's segmented control makes invalid values unreachable from the UI — this is purely a wire-level guard.
- Migration is idempotent (`ALTER TABLE ... ADD COLUMN`). If somehow re-applied, SQLite errors and the migration runner halts cleanly.
- Existing in-flight workspaces created before the migration: NULL `build_mode` → resolves to `"primary"` → identical behavior to today.

## Testing

1. **Unit test** for the precedence resolver (`workspace.buildMode → project.defaultBuildMode → .primary`). Lives alongside the model in `MultiharnessClientTests` or wherever model tests live today.
2. **Integration test** in `SidecarIntegrationTests`: create a project, create two workspaces (one `primary`, one `shadowed`), call `agent.create` for each, capture the system prompt the sidecar uses (via a small test hook or by introspecting the agent's initial state), and assert the addendum appears for `shadowed` and not for `primary`.
3. **Migration test** in `PersistenceTests`: open a v2 DB, run migrations, assert v3 columns exist, assert old rows have NULL.

## Out of scope

- Project settings sheet for editing project defaults independent of workspace creation. (Future PR; will likely also wire `default_provider_id`.)
- Customizable shadowed-mode prompt text per project. (Fixed string in v1.)
- Tool-level gating — blocking the bash tool from running build commands. (Approach A from brainstorming: inform-only.)
- A "primary build target" concept on the project that auto-syncs that worktree's content into the user's primary checkout. (Stretch idea from brainstorming round 1; needs its own design.)
- iOS-side parity for editing project defaults outside workspace creation.
- Reconcile-worktrees feature (separate spec, separate brainstorming round).

## Open questions

None blocking implementation. Two items deliberately punted:

- Whether `default_build_mode` defaults to `primary` or `shadowed` for *new* projects — kept as NULL (= "no project default; falls back to primary") so users opt in.
- Whether the prompt addendum should also list common Bun / Cargo / Gradle / Make commands. Current text gives examples; agent can generalize. Revisit after dogfooding.

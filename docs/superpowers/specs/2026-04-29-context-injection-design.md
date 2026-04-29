# Context Injection — Design

**Date:** 2026-04-29
**Status:** Approved (brainstorming, vibe-coded sign-off)
**Scope:** Per-workspace and per-project free-text instructions that are concatenated onto the agent's system prompt and applied live on every turn (including in-flight sessions, on the next turn).

## Problem

Today the agent's system prompt is fixed by build mode and offers no escape hatch for users who want to give workspace- or project-specific guidance ("always use the `pnpm` runner here", "when touching the iOS code, prefer SwiftUI over UIKit", "never edit files under `vendor/`"). Users have to repeat themselves at the top of every chat.

CLAUDE.md exists for project-level guidance but has two limitations: it's read once at session start (edits don't propagate), and it's a single repo-wide file, so a project that contains multiple worktrees can't have per-worktree guidance.

This feature adds two layered overlays the user controls from the UI:

- **Project context** — applies to every workspace in the project.
- **Workspace context** — applies to one workspace.

Both update the running agent's system prompt on the next turn — no session restart required.

## User-facing model

The right-pane Inspector becomes tabbed. The new **Context** tab shows two stacked panels:

- **Project context** — read-only here. A small `[Edit in project settings →]` button opens a project-settings sheet where it can be edited.
- **Workspace context** — editable `TextEditor` plus a `[Copy from CLAUDE.md]` button that pre-fills the editor with the contents of `<worktreePath>/CLAUDE.md` if that file exists.

Both fields are plain free-text. Empty string means "no overlay at this scope". The user sees what's being injected and edits exactly what's injected — no template, no structured fields.

Edits save automatically (debounced ~500ms). A small "Saved" indicator appears next to the field.

The project-settings sheet is also reachable from the project row in the sidebar via right-click → "Project settings…". This sheet is the home for any future per-project settings.

iOS gets a **read-only** disclosure section inside its workspace view that surfaces the active project + workspace context, so the iPhone user can see what's being injected. Editing on iOS is out of scope for this iteration.

## Architecture

### Data model

Migration v4 (append-only, in `Sources/MultiharnessCore/Persistence/Migrations.swift`):

```sql
ALTER TABLE projects   ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
ALTER TABLE workspaces ADD COLUMN context_instructions TEXT NOT NULL DEFAULT '';
```

`NOT NULL DEFAULT ''` keeps the type plain `String` end-to-end and makes "no overlay" trivially representable. Existing rows are backfilled to `''` by SQLite.

Both `Project` and `Workspace` Codable structs in `Sources/MultiharnessClient/Models/Models.swift` gain `contextInstructions: String`. Default value `""` so JSON missing the field still decodes (relevant if an older sidecar build returns rows without it during a transitional moment).

`PersistenceService.upsertProject` and `upsertWorkspace` round-trip the new column. `loadWorkspace` / `loadProject` map it back.

### Wire protocol

Two new methods, both relayed to the Mac (the Mac owns SQLite):

| Method | Params | Result |
|---|---|---|
| `workspace.setContext` | `{ workspaceId: UUID, contextInstructions: String }` | `{}` |
| `project.setContext`   | `{ projectId: UUID, contextInstructions: String }`   | `{}` |

Mac handlers in `Sources/Multiharness/RemoteHandlers.swift`:

1. Validate the id exists.
2. Update SQLite (`UPDATE workspaces|projects SET context_instructions = ? WHERE id = ?`).
3. Push the new value to any live `AgentSession`(s) by calling new sidecar RPCs (below).
4. Return success.

Two new sidecar-only RPCs (no relay; called by the Mac itself once it has finished persisting):

| Method | Params | Result |
|---|---|---|
| `agent.applyWorkspaceContext` | `{ workspaceId: UUID, contextInstructions: String }` | `{}` |
| `agent.applyProjectContext`   | `{ projectId: UUID, contextInstructions: String }`   | `{}` |

`applyWorkspaceContext` updates one session if one is live; no-op if none. `applyProjectContext` fans out to every live session whose `projectId` matches.

`agent.create` gains two optional params: `projectContext: string`, `workspaceContext: string`. The Mac is the source of truth — when it constructs the create request, it reads both values from SQLite and passes them through. Defaults to empty strings.

`remote.workspaces` and the existing project list responses already serialize the full structs, so the new field travels to iOS automatically with no protocol change.

### Sidecar — composing and live-updating the system prompt

`AgentSession` (in `sidecar/src/agentSession.ts`) gains:

- New `AgentSessionOptions` fields: `projectId: string`, `projectContext: string`, `workspaceContext: string`.
- Private `composeSystemPrompt()` that returns:

  ```
  buildSystemPrompt(buildMode)
  + (projectContext.trim()  ? "\n\n<project_instructions>\n" + projectContext + "\n</project_instructions>"  : "")
  + (workspaceContext.trim() ? "\n\n<workspace_instructions>\n" + workspaceContext + "\n</workspace_instructions>" : "")
  ```

  Tagged delimiters help the model treat each block as a labeled unit and aid debugging. Empty/whitespace-only overlays are dropped entirely (no empty tags).

- Public `setWorkspaceContext(text)` and `setProjectContext(text)`. Each updates the stored field, recomposes, and assigns `this.agent.state.systemPrompt = composed`. pi-agent-core reads `_state.systemPrompt` fresh on every `prompt()`/`continue()` via `createContextSnapshot()`, so the new overlay is visible to the model on the next turn — no agent recreation, no in-flight disruption.

`AgentRegistry` gains:

- `applyWorkspaceContext(workspaceId, text)` — single session if present.
- `applyProjectContext(projectId, text)` — iterates the registry, updates each session whose stored `projectId` matches.

The registry must therefore record `projectId` per session (already implicit; we store it explicitly on the `AgentSession` instance).

### Mac UI

**Inspector tab refactor.** The current `Inspector` body in `Sources/Multiharness/Views/WorkspaceDetailView.swift` becomes a `TabView` with two tabs:

- **Files** — existing changed/untracked list and preview, untouched.
- **Context** — new view containing:
  - A header reading **Project** with the read-only project context text (or muted "No project-wide instructions" placeholder), and an `[Edit in project settings →]` button that opens the project settings sheet.
  - A header reading **Workspace** with a `TextEditor` bound to the workspace's `contextInstructions`, a "Saved"/"Saving…" indicator, and a `[Copy from CLAUDE.md]` button that's enabled only if `<worktreePath>/CLAUDE.md` exists.

**Project settings sheet** — new view opened from a sidebar context-menu entry on the project row ("Project settings…"). Contains a single `TextEditor` for project context plus the "Saved" indicator. This view is the home for future per-project settings.

**Save flow.** A new `ContextStore` (or methods on existing `AgentStore` — pick during implementation) debounces edits ~500ms then calls `control.call("workspace.setContext", …)` or `control.call("project.setContext", …)`. The relay routes to the local Mac handler which updates SQLite and pushes live updates to running sessions via the new sidecar RPCs. On success the store updates its in-memory copy of the workspace/project and flips the indicator to "Saved".

**Copy from CLAUDE.md.** Reads `<worktreePath>/CLAUDE.md` synchronously, writes the contents into the `TextEditor`'s bound text, and triggers the same save path as a manual edit. If the file doesn't exist (the button shouldn't be enabled, but defensively) we show a minor toast/error.

### iOS

`MultiharnessClient` Codable structs decode the new fields automatically — no model work.

In the iOS workspace view, add a **collapsible "Context" disclosure section** (collapsed by default) that displays:

- A "Project" sub-section with the project's `contextInstructions` (read-only).
- A "Workspace" sub-section with the workspace's `contextInstructions` (read-only).
- If both are empty, the disclosure section is hidden entirely.

No new RPCs and no new iOS views beyond this disclosure.

## Edge cases & decisions

- **Long contexts.** Plain text, no length cap in this iteration. The user owns the consequence (token budget). If we discover this is a problem we'll add a soft warning later.
- **Whitespace-only overlays.** Treated as empty when composing; the corresponding tagged block is omitted.
- **Empty `buildSystemPrompt()` base.** Composition still works — empty base + project + workspace just yields the two tagged blocks (or one, or none).
- **Saving while a turn is in flight.** Allowed. The next `prompt()`/`continue()` call picks up the new system prompt; the in-flight call uses what was snapshotted when it started. This matches the rest of the app's "edit during run" semantics.
- **Project context update with many live workspaces.** `applyProjectContext` is a synchronous fan-out across the in-memory registry — O(N) sessions. N is small (single user, single host); no batching needed.
- **Concurrent edits from Mac and iOS.** Out of scope (iOS is read-only here).
- **Older clients reading newer rows / vice versa.** All new fields default to empty string, both at the DB layer and in Codable defaults, so cross-version reads are safe.
- **Migration of existing data.** None needed beyond the column add — empty string is the correct "no overlay" value.

## Test strategy

- **Sidecar unit tests** (`sidecar/test/`):
  - `AgentSession.composeSystemPrompt` — empty/empty, project-only, workspace-only, both, whitespace-only inputs.
  - `AgentSession.setWorkspaceContext` updates `agent.state.systemPrompt` immediately.
  - `AgentRegistry.applyProjectContext` updates exactly the matching sessions.
- **Mac integration tests** (`Tests/`):
  - `PersistenceService` round-trips `contextInstructions` for both projects and workspaces (including default empty).
  - Migrations apply cleanly on a fresh DB and on a v3 DB.
- **Manual smoke (recorded in PR description):**
  - Edit workspace context, prompt the agent, confirm the model acts on the instruction.
  - Edit project context, observe two open workspaces both pick it up on next turn.
  - Copy from CLAUDE.md when the file exists; button disabled when it doesn't.
  - Restart the Mac app, confirm both fields persist.

## Out of scope

- iOS editing UI for context.
- Length caps, token-budget warnings, syntax highlighting, multi-field templates.
- Any change to CLAUDE.md handling (CLAUDE.md still works exactly as before, independently).
- Re-running an already-completed turn after an edit.

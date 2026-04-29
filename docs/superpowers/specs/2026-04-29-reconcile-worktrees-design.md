# Reconcile Worktrees — Design

**Date:** 2026-04-29
**Status:** Approved (vibe-coded sign-off, brainstorming round 2)
**Scope:** Project-level button that takes all workspaces in `.done` or `.inReview` lifecycle states and sequentially merges their branches into a fresh integration worktree. Conflicts are resolved by the project's chosen model via a one-shot sidecar RPC. Bulk review at the end. macOS-only for v1.

## Problem

Multiharness runs N parallel agents in N worktrees. Local builds (Xcode, dev server) are typically scoped to a single checkout — the user can only point one IDE/build at one worktree at a time. The build-mode toggle (shipped) lets agents in non-active worktrees know they're flying blind on builds, but it doesn't solve "I want to test the *combined* result of several finished workspaces in one place."

Today, integrating finished workspaces is a manual `git merge` dance per workspace, with the user resolving conflicts by hand and no clean place to put the result. This design introduces a one-button reconcile flow that produces a fresh, buildable, integration workspace.

## User-facing model

A "Reconcile" button on each project (in both single-project and all-projects sidebar modes). Clicking it opens a sheet that lists the workspaces that qualify (lifecycle state in `.done` or `.inReview`). The user clicks Reconcile, watches a progress panel, and when the run completes the new integration workspace is selected in the sidebar.

The integration workspace:
- is a regular `Workspace` row with a name like `_reconcile-2026-04-29-1530`
- branches from the project's default base branch
- inherits the project's default provider/model
- gets an agent automatically (existing flow)
- starts in lifecycle state `.inReview`

The user can chat with the integration workspace's agent like any other workspace, open it in Xcode, edit files, push branches, archive it, etc. Original source workspaces are untouched.

## Architecture

### Layer summary

- **`ReconcileCoordinator`** (new, `Sources/MultiharnessCore/Stores/ReconcileCoordinator.swift`): `@MainActor @Observable` actor that drives the run, owns published state, exposes `prepare`/`start`/`abort`.
- **`WorktreeService` extensions** (existing file, `Sources/MultiharnessCore/Worktree/WorktreeService.swift`): adds `merge`, `mergeAbort`, `unmergedFiles`, `stage`, `commit`, `isLikelyBinary`. All built on the existing `runGit(...)` primitive. The integration worktree itself is created via the existing `WorkspaceStore.create(...)` path — no new worktree-creation method is needed since the integration workspace is just a regular workspace.
- **`agent.resolveConflictHunk`** (new sidecar RPC, `sidecar/src/conflictResolver.ts` + registration in `sidecar/src/methods.ts`): one-shot LLM completion. Does NOT route through `Agent`/`AgentSession` — uses `pi-ai`'s underlying chat completion directly.
- **`ReconcileSheet`** (new SwiftUI view, `Sources/Multiharness/Views/ReconcileSheet.swift`): single sheet that toggles between trigger and progress UIs based on coordinator phase.
- **Trigger buttons**: small additions to `ProjectPickerHeader` (in `RootView.swift`) and `ProjectDisclosure.header` (in `WorkspaceSidebar.swift`).

### State machine (per run)

```
┌──────────┐  prepare   ┌──────────┐  start   ┌─────────┐
│  ready   │──────────▶ │  ready   │────────▶ │ running │
└──────────┘            │ (rows    │          └────┬────┘
                        │  loaded) │               │
                        └──────────┘     ┌─────────┴─────────┐
                                         ▼                   ▼
                                    ┌─────────┐         ┌─────────┐
                                    │completed│         │ aborted │
                                    └─────────┘         └─────────┘
                                                              │
                                                        ┌─────┴─────┐
                                                        ▼           ▼
                                                  keep partial   delete partial

(any phase can also transition to `failed(message:)` on a setup error)
```

For each row in `running`:
1. Check abort flag → if set, transition to `.aborted` and stop.
2. Set `state = .merging`. Run `git merge --no-ff --no-commit <workspace.branchName>` in the integration worktree.
3. Clean → `git commit` with message `"Reconcile: merge <branch>"`. Set `state = .committed`. Continue.
4. Conflict → set `state = .resolving`. For each unmerged file:
   - If binary/unparseable → log "skipped: needs manual fix", continue.
   - Else → call `agent.resolveConflictHunk` with the file's full content. On `resolved` → write back, `git add`. On `declined` or RPC error → log, leave conflict markers.
5. After file loop:
   - Any markers remaining → `git merge --abort`, mark row `.failed("N files need manual resolution")`. Continue to next workspace.
   - All clean → `git commit`. Mark row `.committed`.

After all rows: bootstrap an agent session for the integration workspace (existing `bootstrapAllSessions` flow), set phase to `.completed`.

### Why per-workspace failure doesn't halt the run

Workspaces are independent until the moment we try to merge them. If workspace A's merge produces a conflict the LLM can't resolve, that's a problem only for A — workspaces B and C may merge cleanly on top of main without involving A's changes. Halting on first failure would prevent valid integrations. The user gets the list of failed workspaces in the progress panel and can fix them manually before re-running reconcile.

### Wire protocol — `agent.resolveConflictHunk`

Request:

```jsonc
{
  "id": "...",
  "method": "agent.resolveConflictHunk",
  "params": {
    "providerConfig": { /* same shape as agent.create */ },
    "filePath": "Sources/Foo/Bar.swift",
    "fileContext": "...full file content with <<<<<<< markers...",
    "language": "swift"
  }
}
```

Response:

```jsonc
{
  "id": "...",
  "result": {
    "outcome": "resolved",
    "content": "...full resolved file content..."
  }
}
```

Or, when the model declines:

```jsonc
{
  "id": "...",
  "result": {
    "outcome": "declined",
    "reason": "ambiguous semantic intent"
  }
}
```

Errors (network failure, model error, timeout) surface as standard RPC errors. The Mac treats any RPC error as "decline" for purposes of resolving that file.

### System prompt for the resolver

A constant in `sidecar/src/conflictResolver.ts`:

> *"You are resolving a 3-way merge conflict. The user has shown you the full text of one file containing one or more `<<<<<<<` / `=======` / `>>>>>>>` conflict markers. Output the complete file with all conflicts resolved — no commentary, no markdown fences, no explanation. If you cannot resolve a conflict because the two sides express incompatible intent that requires human judgment, instead output the literal token `__DECLINED__` followed by a single short sentence explaining why."*

Mac-side post-processing: if the response starts with `__DECLINED__`, parse the trailing reason. Otherwise, validate that the response (a) is non-empty, (b) is at least 50% of `fileContext.length`, and (c) contains no `<<<<<<<` markers. Failing any check → treat as `declined` with reason "malformed response."

## UI

### Trigger sheet

Lists the qualifying workspaces in creation order. Below the list, a single sentence: *"Conflicts will be resolved by your project's chosen model. Original workspaces are not modified."* Buttons: `[ Cancel ]   [ Reconcile ]`.

If zero qualifying workspaces: body says *"No workspaces are in `Done` or `In review`. Mark some workspaces as done first."* Reconcile button is disabled.

If the project has no default model: body shows an error and Reconcile is disabled.

### Progress panel

Live list of rows, one per source workspace, with state + log entries:

```
⠋ fix-keychain-leak    merged clean
⠋ add-codex-oauth      resolving 2 files…
    • Sources/Auth.swift:42 — resolved
    • Sources/Auth.swift:120 — declined: requires human judgment
◌ ios-pairing-multimac pending
```

Footer: `[ Abort ]` while running. After completion: `[ Open integrated workspace ]   [ Close ]`. After abort/failure: `[ Keep partial result ]   [ Delete and close ]`.

### Trigger button placement

- `ProjectPickerHeader` (single-project sidebar mode, `RootView.swift`): new `Image(systemName: "arrow.triangle.merge")` button next to the existing `+` quick-create.
- `ProjectDisclosure.header` (all-projects sidebar mode, `WorkspaceSidebar.swift`): same button next to the per-project filter toggle.

Both present the same `ReconcileSheet`. Buttons are disabled when zero qualifying workspaces or no default model.

## Persistence and identity

The integration workspace is created via the existing `WorkspaceStore.create(...)` path:
- name: `_reconcile-<ISO-timestamp>` (e.g., `_reconcile-2026-04-29T15-30-12Z`)
- branch name: derived as today (`<gitUserName>/<workspace-slug>`), so something like `<user>/_reconcile-2026-04-29t15-30-12z`
- buildMode: nil (inherit project default)

No new schema. No new persisted state about the reconcile run itself. Once the run finishes, the only artifact is the integration workspace and its git history (which records the merge order via the merge commits).

## Error handling

| Failure mode | Behavior |
|---|---|
| LLM RPC error (network, timeout, model error) | Log on row, leave conflict markers in file, continue with next file |
| LLM declines (`__DECLINED__`) | Log reason, leave markers, continue |
| Malformed LLM response | Treat as declined ("malformed response"), continue |
| Binary or unparseable file | Skip LLM, log "needs manual fix", continue |
| File still has `<<<<<<<` after loop | `git merge --abort`, row `.failed`, continue to next workspace |
| Source workspace branch missing | Row `.failed("branch not found")`, continue |
| Integration worktree creation fails | Error in trigger sheet before any merging starts; no cleanup needed |
| Project has no default model | Error in trigger sheet, Reconcile button disabled |
| User clicks Abort | Set flag; loop honors at top of next workspace iteration. In-flight merge completes (or aborts via `git merge --abort` if stuck on conflicts). Partial result preserved. |

LLM RPC timeout: 60 seconds per file.

## Testing

1. **`WorktreeServiceMergeTests`** (`Tests/MultiharnessCoreTests/`): real-git integration tests on temp repos. Cases: clean merge → `.clean`; conflicting merge → `.conflicts(unmergedFiles:)`; `mergeAbort` cleans state; staged + committed file shows in `git log`.
2. **`ReconcileCoordinatorTests`** (`Tests/MultiharnessCoreTests/`): stub `WorktreeService` + sidecar RPC. Cases: empty eligible list throws; clean-merge happy path; conflict-resolved happy path; conflict-declined path; abort mid-run preserves state; LLM RPC error logged but doesn't halt.
3. **`conflictResolver.test.ts`** (`sidecar/test/`): stub the model call. Cases: resolved happy path; `__DECLINED__` parsed correctly; missing/empty content; malformed-detection thresholds.

No UI testing (consistent with rest of project).

## Out of scope (v1)

- iOS trigger (no project-level UI on iOS today; relayed `project.reconcile` is a future add).
- Streaming review per workspace (deferred to "polished v1").
- Side-by-side conflict viewer / per-file edit-then-retry.
- Automatic retry on malformed LLM output.
- Automatic build/test of the integration worktree.
- Lifecycle promotion of source workspaces.
- Persisted lineage record. Git history shows it.
- Mergiraf or other syntax-aware pre-pass. (Possible v2 for non-Swift codebases — Mergiraf doesn't support Swift.)
- Drag-to-reorder source workspaces in the trigger sheet.

## Open questions

None blocking. Two items deliberately punted:

- Whether failed-but-recoverable workspaces (file needed manual fix) should be re-runnable from the integration worktree (right-click, "Retry merging this workspace"). Useful but adds UI surface; deferred.
- Whether the integration workspace's `Workspace.name` should drop the `_` prefix once the user marks it `.done` (i.e., promotes it from "experimental scratch" to "real"). Cosmetic, not now.

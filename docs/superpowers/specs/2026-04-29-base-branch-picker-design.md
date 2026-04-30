# Base Branch Picker — Design

**Date:** 2026-04-29
**Status:** Approved (brainstorming round 1)
**Scope:** Replace the free-text "Base branch" field on the workspace-create sheet (Mac + iOS) with a picker that lets the user choose between `origin/<branch>` and the local `<branch>`, sourced from real refs in the repo. Add a Mac-only project setting for the per-project default base branch using the same picker.

## Problem

Today, new worktrees are cut from whatever local ref the user types into a free-text field (default: the project's `defaultBaseBranch`, typically `"main"`). The sidecar runs a best-effort `git fetch origin` immediately before `git worktree add` (`Sources/MultiharnessCore/Git/WorktreeService.swift:34-37`), but that fetch is wasted: the resulting worktree still branches off the *local* ref, which can be arbitrarily stale.

Two related problems fall out of this:

1. **No way to branch off latest upstream.** The user has to manually `git pull` the local default branch in the project's primary checkout before creating a workspace, or the new worktree starts behind.
2. **Free-text is error-prone.** Users typo branch names, type refs that don't exist, or aren't sure what's available — particularly on iOS where they don't have a terminal handy.

The fix is to make the choice explicit (origin vs local) and surface real branch names from the repo.

## User-facing model

The workspace-create sheet's "Base branch" control becomes a **branch picker**:

- A segmented control at the top — **Origin** | **Local** — selects which side of the repo to list from.
- A search field below filters the list as the user types.
- A scrollable list shows matching branches; the user picks one.
- A small **↻** refresh button next to the segmented control re-runs `git fetch origin` and refreshes the list.

The **Origin** segment is disabled (greyed) when the project has no `origin` remote or the most recent listing failed to reach it. The disabled-state caption explains why ("No `origin` remote configured" vs. "Failed to reach `origin`").

The picker's selected value is a single fully-qualified ref string — `origin/main` or `main` — which is what `git worktree add` already accepts at `WorktreeService.swift:34-37`. No change to that path.

A new **Project Settings** screen on Mac exposes the project's `defaultBaseBranch` for editing using the same picker component. iOS does not get this screen in v1.

## Architecture

### Data model

`projects.default_base_branch` already exists in SQLite (set at project creation, read at `Sources/Multiharness/RemoteHandlers.swift:218`). No migration needed.

The stored format changes from "branch name" (e.g., `main`) to "fully-qualified ref" (e.g., `origin/main` or `main`). Existing rows keep their bare-branch value and continue to resolve as local refs — backward-compatible because `git worktree add main` is what they did before.

### Wire protocol

Two new RPC methods, both Mac-only and relayed for iOS via the existing relay (`sidecar/src/relay.ts`).

#### `project.listBranches`

```ts
// Request
{ projectId: string, refresh?: boolean }

// Response
{
  origin: string[] | null,          // null when originAvailable is false
  local: string[],
  originAvailable: boolean,
  originUnavailableReason?: "no_remote" | "fetch_failed",
  fetchedAt: number                  // unix ms
}
```

Behavior on the Mac handler:

1. If `refresh: true` or no cached entry exists for this project, run `git fetch origin` with a 5s timeout. Errors do not throw — they set `originAvailable: false, originUnavailableReason: "fetch_failed"`.
2. Enumerate local branches: `git branch --format='%(refname:short)'`.
3. If a `origin` remote exists, enumerate remote-tracking branches: `git for-each-ref refs/remotes/origin --format='%(refname:short)'`, dropping any entry equal to `origin/HEAD`. The returned strings include the `origin/` prefix (e.g., `origin/main`).
4. If no `origin` remote: `originAvailable: false, originUnavailableReason: "no_remote"`.
5. Cache the result in-memory keyed by `projectId` for the lifetime of the Mac process. The cache is invalidated by any subsequent call with `refresh: true`.

Branches are returned alphabetically (the natural order of `for-each-ref` and `git branch`). The picker preserves that order.

#### `project.update`

```ts
// Request
{ projectId: string, defaultBaseBranch: string }

// Response
{ projectId: string, defaultBaseBranch: string }
```

Updates `projects.default_base_branch` in SQLite. Validation is best-effort — the value is checked against the cached branch list (if present); a mismatch produces a non-blocking `warning` field in the response but the row is still updated, since `origin/<x>` may briefly disappear during force-pushes.

The handler is structured so additional editable fields can be added later by extending the request shape; v1 only accepts `defaultBaseBranch`.

### Worktree creation path (unchanged)

`workspace.create` still takes a `baseBranch: string` param. The default-resolution chain at `Sources/Multiharness/RemoteHandlers.swift:218` is unchanged:

```
params.baseBranch  →  project.defaultBaseBranch  →  "main"
```

The string is passed to `git worktree add ... <baseBranch>` as today. No new code in `WorktreeService.swift`.

`WorkspaceStore.swift:220` (quick-create) is unchanged: it inherits the active workspace's `baseBranch`, falling back to project default. If the inherited ref no longer exists on disk, the existing sidecar error path surfaces it.

### Mac UI

`Sources/Multiharness/Views/Sheets.swift` — `NewWorkspaceSheet` (the existing `TextField("Base branch", ...)` at line ~97):

- Replace the existing `TextField("Base branch", text: $baseBranch, prompt: Text(proj.defaultBaseBranch))` with a new `BranchPicker` SwiftUI view.
- On sheet appear, call `project.listBranches({ projectId })`.
- Show a progress spinner until the response arrives (or 5s elapses).
- Pre-select the toggle and branch from the project's `defaultBaseBranch`: parse leading `origin/` to set the toggle to Origin, otherwise Local; pre-select the matching list entry.
- If the saved default isn't in the list, fall back to the first available entry on the appropriate side.

New view: `Sources/Multiharness/Views/ProjectSettingsView.swift`. Reachable from a "Settings…" button or context menu on the project row — exact entry point is up to the implementer to match existing project actions. The view contains one field: **Default base branch**, rendered as the same `BranchPicker`. Save calls `project.update({ projectId, defaultBaseBranch })`.

### iOS UI

`ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`:

- Same replacement: free-text field → `BranchPicker`.
- Same RPC flow, but the call goes through the relay to the Mac.
- No project settings screen in v1.

The `BranchPicker` component lives in `Sources/MultiharnessClient/Views/` so both targets share it. (`MultiharnessClient` is the cross-platform package per CLAUDE.md.)

### Error handling

- **`project.listBranches` returns `originAvailable: false`:** Origin segment disabled with the appropriate caption from `originUnavailableReason`.
- **`project.listBranches` RPC fails entirely:** the picker shows an inline error row with a Retry button. The user cannot create a workspace until the call succeeds, since we no longer accept arbitrary text.
- **Empty local branch list** (theoretically impossible — there's always `HEAD`'s branch): show an empty-state caption "No local branches".
- **Empty origin branch list** (remote has zero branches): Origin segment disabled with caption "No remote branches".
- **Search filter matches nothing:** the list area shows "No branches match `<query>`" and the create button is disabled until the user clears the filter or selects a branch.

## Caching strategy

Per-app-session, in-memory, manual refresh:

- `project.listBranches` results live in a `Map<projectId, BranchListing>` on the Mac handler (`RemoteHandlers.swift`). The cache is in-process — it is wiped any time the Mac app relaunches.
- The picker's **↻** button passes `refresh: true` to bypass the cache and re-run `git fetch origin`.

This is option **(B)** from the brainstorm. Auto-refresh on app launch (option C) is rejected as overkill — Mac app restarts already invalidate the cache, and stale branch lists are low-stakes (worst case, the user clicks ↻).

## Testing

- **Sidecar:** No new sidecar code (the relayed methods execute on the Mac), so no Bun-side tests beyond ensuring relay-routing of the new method names doesn't regress.
- **Mac (XCTest):**
  - `project.listBranches` returns expected origin + local lists for a fixture repo with both.
  - `originAvailable: false, reason: "no_remote"` for a fixture repo with no `origin`.
  - `originAvailable: false, reason: "fetch_failed"` when the configured `origin` URL is unreachable.
  - Cache hit returns identical output without re-running `git fetch`.
  - `refresh: true` bypasses cache.
  - `project.update` writes to SQLite and returns the new value; subsequent reads via the existing project-load path see it.
- **iOS / SwiftUI:** Manual test of the picker behavior; no new XCTest coverage in v1.

## Out of scope

- Tags, non-`origin` remotes, branch metadata (last commit, author).
- Editing or creating remote branches from the picker.
- Project settings on iOS.
- Other editable project fields (display name, repo path, etc.) — the `project.update` schema is shaped to allow them later, but v1 only accepts `defaultBaseBranch`.
- Background refresh on app launch.
- Showing both origin and local branches in a single intermixed list.

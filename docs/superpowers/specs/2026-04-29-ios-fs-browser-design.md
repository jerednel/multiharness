# iOS Add-Project: remote filesystem browser

## Goal

In the iOS app's **Add project** sheet, replace the manual `repoPath` text field with a folder browser that drills through the Mac's filesystem (over the existing relay), letting the user pick any directory as a project root.

The current sheet (`ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`, `NewProjectSheet`) offers two ways to choose a path: a scanned list of git repos in common locations, and a free-text `TextField`. The text field is the only escape hatch when the user's repo lives outside `~/dev`, `~/code`, etc., but typing absolute paths on a phone is painful and error-prone.

## Non-goals

- No bookmarks / quick-access shortcuts (Documents, Desktop, Volumes).
- No security-scoped bookmark resolution for TCC-protected directories. Listing those directories may fail with "Operation not permitted"; we surface the error and the user navigates elsewhere.
- No "create folder here" affordance.
- No in-browser repo init (`git init`).

## Architecture

### New relayed RPC: `fs.list`

Lives next to `project.scan` in the relay path.

**Request**
```jsonc
{ "method": "fs.list", "params": { "path": "/Users/jeremy" } }
```
- `path` — absolute path. If missing or empty, defaults to `$HOME`.

**Response**
```jsonc
{
  "path": "/Users/jeremy",        // canonicalized absolute path of the listed directory
  "parent": "/Users",             // null when path is "/"
  "entries": [
    { "name": "code", "path": "/Users/jeremy/code", "isGitRepo": false },
    { "name": "multiharness", "path": "/Users/jeremy/multiharness", "isGitRepo": true }
  ]
}
```

Rules:
- Only directories are returned (regular files are filtered out).
- Hidden entries (names starting with `.`) are excluded.
- `isGitRepo` is true when the entry contains a `.git` *directory or file* (worktrees use a file).
- Entries sorted ASCII-case-insensitively by `name`.

**Errors**
- Path doesn't exist or isn't a directory → relay error `"path does not exist or is not a directory"`.
- `FileManager` throws on listing (e.g., TCC denial) → relay error with the underlying message.

### Sidecar wiring

`sidecar/src/methods.ts` — append `"fs.list"` to the existing relayed methods array (lines 146–155). No other sidecar code changes.

### Mac handler

`Sources/Multiharness/RemoteHandlers.swift` — add a new `fsList(params:)` handler and register it in `RemoteHandlers.register`. Implementation:
- Resolve `path` param; default to `FileManager.default.homeDirectoryForCurrentUser.path` if missing.
- Verify the path exists and is a directory.
- `contentsOfDirectory(at:includingPropertiesForKeys:[.isDirectoryKey],options:[.skipsHiddenFiles])`.
- For each `URL`, keep only directories. Probe `entry/.git` with `fileExists(atPath:)` (matches dirs *or* files).
- Compute `parent` via `URL.deletingLastPathComponent()`; return `null` if path is `/`.

### Client glue (MultiharnessClient)

No changes needed — the `MultiharnessClient` package's `ControlClient.call` already handles arbitrary methods. The new types live in `ConnectionStore` (iOS-only).

### iOS — `ConnectionStore`

`ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — add:

```swift
public struct FolderEntry: Identifiable, Sendable, Hashable {
    public let name: String
    public let path: String
    public let isGitRepo: Bool
    public var id: String { path }
}

public struct FolderListing: Sendable {
    public let path: String
    public let parent: String?
    public let entries: [FolderEntry]
}

public func listFolders(path: String?) async throws -> FolderListing { ... }
```

`listFolders` calls `fs.list`, parses the response into the structs. Empty `path` → omit the param.

### iOS — `BrowseFolderView`

New file: `ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift`.

- `@Bindable var connection: ConnectionStore`
- `let initialPath: String?` (nil → start at `$HOME` via the RPC default)
- `let onPick: (FolderEntry) -> Void` — called when the user taps "Use this folder"; the closure receives an entry whose `path` is the *current* listing path and `name` is its basename.

Behavior:
- On `task`, fetch the listing.
- Header: full current path (`Text` with `.lineLimit(1)`, `.truncationMode(.head)`), with the `parent` reachable via the system back button (each subdirectory is pushed via `NavigationLink`, so the back stack handles ascent).
- Body: list of folder rows. Each row: `folder` SF Symbol, name, optional "git" capsule badge when `isGitRepo`. Tapping a row pushes another `BrowseFolderView` initialized at that subpath.
- Toolbar trailing: **"Use this folder"** button. Calls `onPick` with an entry representing the *current* directory, then dismisses the sheet ancestor (see "popping" below).
- Error state: `Text` with the error message; "Retry" button re-runs the fetch.
- Loading state: centered `ProgressView`.

**Popping back to the sheet root.** `NewProjectSheet`'s existing `NavigationStack` is converted to use a `@State var browsePath = NavigationPath()` binding. Each subdirectory push appends the entry to that path; "Use this folder" sets `repoPath` (and `name` if empty) on the parent, then resets `browsePath = NavigationPath()` to pop all the way back to the form root.

### iOS — `NewProjectSheet` restructure

`ios/Sources/MultiharnessIOS/Views/CreateSheets.swift`:

1. **Section 1 (top, new) — "Browse"**
   - A single `NavigationLink` row labelled **"Browse for a folder"**.
   - When `repoPath` is set, show its absolute path beneath in `.caption2` muted text, head-truncated.
2. **Section 2 — "Pick a discovered repository"** (unchanged from current code).
3. **Section 3 — "Details"**
   - `TextField("Display name", text: $name)`
   - `TextField("Default base branch", text: $baseBranch)`
4. The current `TextField("/Users/<you>/dev/<repo>", text: $repoPath)` is **removed**.

Selection flow:
- Tapping a discovered repo → existing behavior: sets `repoPath`, autofills `name` if empty.
- Tapping "Use this folder" inside the browser → identical effect.
- The "Add" button's `canCreate` predicate is unchanged (`name` and `repoPath` non-empty).

## Error handling

| Scenario | Surface |
|---|---|
| RPC fails (network, sidecar down) | `BrowseFolderView` error state + Retry button |
| `path` doesn't exist | RPC returns error → error state |
| TCC permission denied (Documents/Desktop/Downloads on a fresh install) | RPC returns error with the underlying `NSError` message → error state. User uses back button. |
| Empty directory | Show "No subfolders." (`.caption`, secondary) |
| `path == "/"` | `parent == nil`. The browser at `/` has no upward `NavigationLink`; the sheet's normal back button still closes the view. |

`project.create` already validates that `repoPath` is a `.git`-containing directory and rejects otherwise — so picking a non-repo folder via the browser still errors at submission time, same as today's free-text path. No new validation needed in the browser itself.

## Testing

- **Sidecar:** add a unit test in `sidecar/test/` if there's existing coverage for relayed methods. (`fs.list` is dispatch-only on the sidecar; the Mac handler holds the logic.) If no comparable test exists for `project.scan`, skip — Swift-side test is the meaningful one.
- **Swift:** extend `Tests/MultiharnessCoreTests/` with a unit test for the new `fsList` handler against a tmpdir tree containing: a normal subdirectory, a git repo (with `.git` dir), a worktree-style entry (with `.git` *file*), a hidden `.cache` dir, and a regular file. Assertions: only directories returned, hidden entries excluded, `isGitRepo` correct for both flavors. Note: the handler currently lives in the executable target `Sources/Multiharness/RemoteHandlers.swift`, which is not test-importable. The handler's pure listing logic should be extracted into a small testable helper (e.g. `Sources/MultiharnessCore/RemoteFs.swift`) so the test target can exercise it directly.
- **Manual iOS smoke test** post-build (`bash scripts/build-ios.sh` then run on a sim or paired device): launch Add project, tap Browse, descend a few levels, tap a folder containing `.git`, confirm `repoPath` populated and `name` autofilled, tap Add, confirm project appears in the list.

## Files touched

| Path | Change |
|---|---|
| `sidecar/src/methods.ts` | Add `"fs.list"` to relayed methods array |
| `Sources/MultiharnessCore/RemoteFs.swift` | New: pure listing helper (`listFolders(path:) -> [FsEntry]`-style) — testable from `MultiharnessCoreTests` |
| `Sources/Multiharness/RemoteHandlers.swift` | New `fsList` handler that calls into `RemoteFs` + registration |
| `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` | New `FolderEntry`/`FolderListing` types + `listFolders` |
| `ios/Sources/MultiharnessIOS/Views/BrowseFolderView.swift` | New file |
| `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` | Restructure `NewProjectSheet` |
| `Tests/MultiharnessCoreTests/RemoteFsTests.swift` | New test for the `RemoteFs` listing helper |
| `ios/project.yml` | Re-run `xcodegen` if `BrowseFolderView.swift` is added (build script handles this automatically) |

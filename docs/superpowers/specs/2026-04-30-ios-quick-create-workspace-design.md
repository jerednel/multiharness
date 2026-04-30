# iOS quick-create workspace + global default model

**Status:** spec
**Date:** 2026-04-30

## Goal

On the iOS app, add a "+" button next to each project in `WorkspacesView` that
instantly creates a new workspace with inherited settings — mirroring the Mac's
existing `WorkspaceStore.quickCreate`. If any required setting can't be
resolved through the inheritance chain, fall back to the existing
`NewWorkspaceSheet` pre-filled with whatever the server could suggest, so the
user only has to fill in the missing pieces.

In addition, introduce a **global default provider+model** stored in the Mac's
app settings. This becomes a new fallback step in the inheritance chain used
by both the Mac's existing quick-create button and the new iOS one — covering
the case where a project has no defaults set and there's no prior workspace to
inherit from.

## Background

The Mac already has `WorkspaceStore.quickCreate` (`Sources/MultiharnessCore/
Stores/WorkspaceStore.swift:212`), invoked by the "+" button in
`WorkspaceSidebar`. It auto-names with a random unique slug
(`RandomName.generateUnique`) and inherits provider, model, and base branch
from the most recent workspace in the same project, falling back to the
project's defaults.

The iOS app's only path today is the full `NewWorkspaceSheet` (`ios/Sources/
MultiharnessIOS/Views/CreateSheets.swift:4`), which always requires the user to
type a name, pick a project, pick a provider, and pick a model.

iOS's `RemoteProject` does not expose `defaultProviderId`, `defaultModelId`, or
`defaultBaseBranch`, and `RemoteWorkspace` does not expose `providerId` or
`modelId`. So iOS cannot compute inheritance locally; it must ask the Mac.

## Non-goals

- Configuring the global default from iOS. Mac-only for now; iOS reads the
  resolved values implicitly through the relay.
- Changing the existing toolbar-menu "New workspace" flow on iOS.
- Exposing project/workspace defaults in `RemoteProject` / `RemoteWorkspace`.

## Design

### 1. Global default provider+model

**Storage.** Two new rows in the existing `settings` key/value table:

| key                  | value                                |
| -------------------- | ------------------------------------ |
| `default_provider_id`| Provider UUID, as string             |
| `default_model_id`   | Model identifier, as string          |

Stored as a pair because a model id is only meaningful in combination with the
provider that knows how to resolve it. No schema migration is needed; the
`settings` table is already key/value (`Sources/MultiharnessCore/Persistence/
Migrations.swift:44`).

**Read/write API.** Add two methods on `AppStore` (the natural owner of
provider/project state — same place that already exposes
`setProjectDefaultBuildMode`):

```swift
public func getGlobalDefault() -> (providerId: UUID, modelId: String)?
public func setGlobalDefault(providerId: UUID?, modelId: String?) throws
```

`setGlobalDefault(nil, nil)` clears both keys. The accessor returns `nil` if
either key is absent, malformed, or references a provider that no longer
exists — the latter is an automatic invalidation rather than a hard error,
since provider deletion is normal and the user will reconfigure if they care.

**UI.** Add a new tab `defaults` to `SettingsSheet`
(`Sources/Multiharness/Views/Sheets.swift:266`):

```
[ Providers ] [ Remote access ] [ Permissions ] [ Sidebar ] [ Defaults ]
```

The Defaults tab contains a single section:

- A `Picker` for "Default provider" (rows: `<None>` + every configured
  provider).
- When a provider is picked, reuse the existing `ModelPicker` to choose a
  default model from that provider's discovered model list.
- A "Clear" button that resets both to nil.

This is intentionally narrow scope — just provider+model. Future global
defaults (e.g. base branch) can be added to the same tab.

### 2. Inheritance chain (updated)

`WorkspaceStore.quickCreate` and the new relay handler (Section 3) both use
this chain:

| field       | priority order                                                                               |
| ----------- | -------------------------------------------------------------------------------------------- |
| `provider`  | most recent workspace in this project → project default → **global default** → first available |
| `model`     | most recent workspace → project default → provider default → **global default** → error      |
| `baseBranch`| most recent workspace → project default                                                      |
| `buildMode` | project default (no inheritance from workspace)                                              |
| `name`      | `RandomName.generateUnique` scoped to existing workspaces in the project                     |

The global default applies independently to each field: if the global default
provider exists but the project's previous workspace already has one, the
previous workspace wins. If the global default's provider id no longer matches
a configured provider, it's treated as absent.

If the chain cannot produce a `(provider, model)` pair, the operation does not
silently fall through to the first available provider with an empty model.
Instead it surfaces a "needs input" outcome (see Section 3).

### 3. New relay method: `workspace.quickCreate`

Routed through the relay just like `workspace.create`. Mac-side handler in
`Sources/Multiharness/RemoteHandlers.swift`.

**Implementation strategy.** The handler does *not* call
`WorkspaceStore.quickCreate` and catch errors, because on the `needs_input`
path it must return the partial resolution (`suggested`) and the gaps
(`missing`) — information that a thrown error can't carry cleanly. Instead,
factor the resolution step out of `WorkspaceStore.quickCreate` into a small
helper:

```swift
struct QuickCreateResolution {
    let providerId: UUID?
    let modelId: String?
    let baseBranch: String
    let buildMode: BuildMode?   // project default; nil = primary
    let name: String            // pre-generated unique slug
    var missing: [String] { /* ["provider"], ["model"], or both */ }
}

extension WorkspaceStore {
    func resolveQuickCreateInputs(
        project: Project,
        providers: [ProviderRecord],
        globalDefault: (UUID, String)?
    ) -> QuickCreateResolution
}
```

Both call sites use it:
- `WorkspaceStore.quickCreate` calls `resolveQuickCreateInputs`, throws
  `QuickCreateError.noProviderAvailable` if `missing` is non-empty, else
  proceeds to `create(...)`.
- The relay handler calls `resolveQuickCreateInputs`, then either calls
  `create(...)` and returns `status: "created"`, or builds and returns the
  `needs_input` payload.

**Request:**

```json
{ "id": "...", "method": "workspace.quickCreate", "params": { "projectId": "<uuid>" } }
```

**Response — created:**

```json
{
  "status": "created",
  "workspace": {
    "id": "<uuid>",
    "name": "fluffy-otter",
    "branchName": "...",
    "worktreePath": "...",
    "lifecycleState": "in_progress",
    "modelId": "...",
    "buildMode": "primary"
  }
}
```

The `workspace` object matches the shape returned by `workspace.create`.

**Response — needs input:**

```json
{
  "status": "needs_input",
  "missing": ["provider", "model"],
  "suggested": {
    "name": "fluffy-otter",
    "baseBranch": "main",
    "buildMode": "primary",
    "providerId": "<uuid or null>",
    "modelId": "<string or null>"
  }
}
```

- `missing` lists exactly the fields that could not be resolved through the
  chain. The set is `["provider"]`, `["model"]`, or `["provider", "model"]`.
- `suggested` is a best-effort pre-fill: every value the chain *did* manage
  to resolve, including the pre-generated random `name`. The same name is
  later used by the iOS sheet so the user doesn't see a different slug than
  what was implied by the click.
- Returning a 200-shaped JSON-RPC `result` (rather than an `error`) keeps
  iOS's call site simple — one path, one response shape, parsed by status.

**Error response (genuine failures only):**

```json
{ "id": "...", "error": { "code": "bad_request", "message": "project not found" } }
```

Reserved for invariant violations: bad UUID, project doesn't exist. Missing
inheritance is a normal outcome, not an error.

### 4. iOS UI — "+" button next to each project

**View change.** In `WorkspacesView` (`ios/Sources/MultiharnessIOS/Views/
WorkspacesView.swift:191`), the `DisclosureGroup` label currently renders:

```
[folder] <project name>  <count badge>
```

Add a `plus.circle` button between the project name and the count badge:

```
[folder] <project name>  [+]  <count badge>
```

Tap behavior:

```swift
Button {
    Task { await connection.quickCreateWorkspace(projectId: group.project.id) }
} label: {
    Image(systemName: "plus.circle")
        .font(.body)
}
.buttonStyle(.borderless)
.disabled(connection.providers.isEmpty)
```

`buttonStyle(.borderless)` is required so SwiftUI doesn't dispatch the
`DisclosureGroup`'s expand/collapse on tap.

**Store change.** Add to `ConnectionStore`:

```swift
public enum QuickCreateOutcome: Sendable {
    case created                          // workspace will appear via refresh
    case needsInput(WorkspaceSuggestion)
    case failed(String)
}

public func quickCreateWorkspace(projectId: String) async -> QuickCreateOutcome
```

Implementation:

1. Call `workspace.quickCreate` with `{ projectId }`.
2. Decode the response.
3. On `status: "created"`: trigger `refreshWorkspaces()` and return `.created`.
4. On `status: "needs_input"`: return `.needsInput(suggestion)` with the
   parsed `suggested` payload (and the `missing` array, if the caller wants
   to display it).
5. On a relay error: return `.failed(message)`.

`WorkspacesView` owns the resulting UI: on `.created`, do nothing — the new
workspace shows up via the existing event-driven refresh; on `.needsInput`,
set `preselectedProjectId`, stash the suggestion in a new `@State` var, and
flip `showingNewWorkspace = true`; on `.failed`, surface inline (match the
rename flow's error pattern).

**Sheet change.** Extend `NewWorkspaceSheet`'s init to accept an optional
`WorkspaceSuggestion`:

```swift
public struct WorkspaceSuggestion: Sendable {
    public let name: String
    public let baseBranch: String?
    public let providerId: String?
    public let modelId: String?
    public let buildMode: BuildMode?
}

struct NewWorkspaceSheet: View {
    var preselectedProjectId: String? = nil
    var suggestion: WorkspaceSuggestion? = nil   // NEW
    // ...
}
```

When `suggestion` is non-nil, the existing `.onAppear` block seeds `name`,
`baseBranch`, `providerId`, `modelId`, and `buildMode` from it, overriding the
current defaults. All fields stay editable. The "Create" button still calls
`workspace.create` (not `quickCreate`); once the user has filled in the gaps,
this is just a normal creation.

### 5. Mac parity

Update `WorkspaceStore.quickCreate` to consult the global default in two
places:

```swift
let providerId = inherit?.providerId
    ?? project.defaultProviderId
    ?? globalDefault?.providerId        // NEW
let modelId = inherit?.modelId
    ?? project.defaultModelId
    ?? provider.defaultModelId
    ?? globalDefault?.modelId           // NEW
```

The signature gains a `globalDefault: (UUID, String)?` parameter (resolved by
the caller from `AppStore`). The Mac's "+" button in `WorkspaceSidebar`
benefits automatically.

The Mac's quick-create error path (`QuickCreateError.noProviderAvailable`)
stays — Mac-side, no provider+model is a terminal user-facing error rather
than a "needs input" dialog, since the Mac UI already has the full
`NewWorkspaceSheet` available one click away. We don't need to unify these
paths.

## Open questions

None outstanding. Resolved during brainstorming:

- Defaults UI lives in a new "Defaults" tab in `SettingsSheet`.
- The recovery sheet pre-fills *editable* values (no read-only treatment for
  global-default-derived fields).
- Global default is configurable on Mac only.
- `ConnectionStore.quickCreateWorkspace` returns a `QuickCreateOutcome`;
  view-state plumbing stays on `WorkspacesView`.
- On `needs_input`, the iOS sheet opens immediately rather than via a toast
  — the user tapped "+" expecting a workspace, the sheet is a continuation.

## Test plan

### Unit tests (Mac)

- `WorkspaceStoreTests`: extend the existing `quickCreate` test cases to
  cover:
  - global default used when project has no defaults and no prior workspace.
  - global default's provider id pointing at a deleted provider falls back
    to first available.
  - global default ignored when project has a default.

### Sidecar / relay tests

- `RemoteHandlersTests` (or wherever existing relay handler tests live):
  - `workspace.quickCreate` succeeds and returns `status: "created"` when
    inheritance resolves.
  - returns `status: "needs_input"` with correct `missing` array and
    `suggested` payload when no provider exists.
  - returns `bad_request` for an invalid `projectId`.

### Manual / iOS

- iOS: tap "+" on a project with a prior workspace → workspace appears,
  no sheet.
- iOS: tap "+" on a fresh project with no providers → sheet opens,
  prefilled with `name` and `baseBranch`, provider/model fields empty.
- iOS: tap "+" on a fresh project with the global default configured →
  workspace appears, no sheet.
- Mac: configure global default in Settings → Defaults → tap Mac's "+"
  on a fresh project → workspace created using global default.
- Mac: clear global default → tap "+" on a fresh project → existing
  `noProviderAvailable` error surfaces.

## File-level changes (preview)

- `Sources/MultiharnessCore/Stores/AppStore.swift` — add
  `getGlobalDefault` / `setGlobalDefault`.
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — extend
  `quickCreate` with the global-default fallback.
- `Sources/Multiharness/Views/Sheets.swift` — add `Defaults` tab.
- `Sources/Multiharness/RemoteHandlers.swift` — register and implement
  `workspace.quickCreate`.
- `sidecar/src/methods.ts` — declare `workspace.quickCreate` as a relay
  method (mirrors `workspace.create`).
- `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` — add
  `quickCreateWorkspace`, `WorkspaceSuggestion`, `QuickCreateOutcome`.
- `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift` — render the
  "+" button, handle the outcome.
- `ios/Sources/MultiharnessIOS/Views/CreateSheets.swift` — accept a
  `suggestion` parameter on `NewWorkspaceSheet`.

---
title: Quick-Create Workspace + All-Projects Sidebar Mode
date: 2026-04-29
status: draft
---

# Quick-Create Workspace + All-Projects Sidebar Mode

## Goal

Make it fast to spin up another workspace on the same project without going through the full New Workspace sheet, and let the user view all projects and their workspaces at once in a collapsible sidebar — similar to Conductor's project tree.

## User stories

1. While iterating on workspace `Munich`, I click a `+` next to the project header and a new workspace appears immediately, named e.g. `brave-otter`, using the same provider/model/base branch as Munich. I start chatting in it without filling out any form.
2. I open Settings, switch the sidebar to "All projects (collapsible)" mode, and see every project as a disclosure group containing its workspaces. Each project header has its own `+` for quick-create.
3. In all-projects mode, I click a small filter icon on a project header and toggle "Group by status" to see that project's workspaces grouped into In Progress / In Review / Done / Backlog / Cancelled.

---

## Feature 1 — Quick-create `+`

### Behavior

- One-click creation of a new workspace under the current/target project.
- Name is generated as `<adjective>-<noun>` from a static built-in list.
- Settings inheritance:
  - If a workspace is currently selected → copy `providerId`, `modelId`, `baseBranch` from it.
  - Else → use `project.defaultProviderId`, `project.defaultModelId`, `project.defaultBaseBranch`.
  - If no provider can be resolved (no selected workspace, no project default, no providers configured) → button is disabled with tooltip "Add a provider in Settings".
- Workspace immediately becomes the selected workspace and is shown in the detail view.

### Random name generator

- New file: `Sources/MultiharnessCore/Worktree/RandomName.swift`
- Two static arrays bundled in `MultiharnessCore`:
  - `~30` adjectives (e.g. `brave`, `swift`, `quiet`, `gentle`, `bold`, …)
  - `~30` nouns (e.g. `otter`, `comet`, `lotus`, `ember`, `harbor`, …)
- API: `RandomName.generate() -> String` returns `"<adj>-<noun>"`.
- Collision handling: caller (the store) checks against existing slugs in the project. On collision, retry `generate()` up to 5 times. If all 5 collide, fall back to `"<adj>-<noun>-2"`, `"-3"`, … until unique.

### Store API

`WorkspaceStore` gets:

```swift
@discardableResult
public func quickCreate(project: Project) throws -> Workspace
```

Implementation:
1. Resolve provider/model/baseBranch from selected workspace, falling back to project defaults.
2. Generate a unique name via `RandomName` + collision check against existing workspace slugs in this project.
3. Resolve `gitUserName` the same way the existing `create(...)` flow does.
4. Delegate to existing `create(project:name:baseBranch:provider:modelId:gitUserName:)`.

### UI placement

- Single-project mode: small `+` button (`Image(systemName: "plus")` inside a `Button(.borderless)`) sits inline next to the project picker dropdown in the sidebar header. Tap → `workspaceStore.quickCreate(project:)`.
- All-projects mode: identical `+` sits inline on each project's disclosure header.
- The toolbar's "New workspace" button (full sheet) stays in both modes — used when you want to override defaults.

### Disabled state

`+` is disabled when:
- No project context (single-project mode with no selected project)
- No providers configured AND no inherited provider available
- A worktree creation is already in flight (optional; can be added later)

---

## Feature 2 — All-projects sidebar mode

### Mode toggle

- New `enum SidebarMode: String, Codable { case singleProject, allProjects }` in `MultiharnessClient/Models`.
- New stored property `sidebarMode: SidebarMode` on `AppStore`, persisted to `UserDefaults` under key `"MultiharnessSidebarMode"`.
- Default: `.singleProject` (preserves current behavior for existing users).

### Single-project mode (current, mostly unchanged)

- Project picker dropdown header at the top of the sidebar (existing `ProjectPickerHeader`).
- Workspaces grouped by lifecycle below (existing `WorkspaceSidebar`).
- New: inline `+` quick-create button next to the project picker dropdown.

### All-projects mode (new)

- No project picker dropdown at the top.
- Sidebar renders one `DisclosureGroup` per project in `appStore.projects`.
- Each project header row contains:
  - `Image(systemName: "folder")`
  - Project name
  - Spacer
  - Inline `+` quick-create button (calls `workspaceStore.quickCreate(project: <thisProject>)`)
  - Filter icon (`Image(systemName: "line.3.horizontal.decrease")`) opening a small menu with a "Group by status" toggle (persisted per-project)
- Underneath the header, the project's non-archived workspaces:
  - **Default (flat)**: sorted by `createdAt` descending. Each row prefixed by a small colored dot (6pt) indicating lifecycle state.
  - **Group-by-status**: same lifecycle-grouped layout used in single-project mode, just nested under the project disclosure.
- Disclosure expansion state persisted per-project to `UserDefaults` as `"MultiharnessProjectExpanded.<projectId>"` → `Bool`, default `true`.
- "Group by status" toggle persisted per-project as `"MultiharnessProjectGroupByStatus.<projectId>"` → `Bool`, default `false`.

### Selection behavior

- Tapping a workspace in all-projects mode sets `workspaceStore.selectedWorkspaceId` AND `appStore.selectedProjectId` to that workspace's project. This keeps the rest of the app (which keys off `selectedProjectId`) working without further changes.

### Data loading

- New `WorkspaceStore.loadAll()` that calls `env.persistence.listWorkspaces(projectId: nil)` and stores the full set in `workspaces`.
- Existing `WorkspaceStore.load(projectId:)` stays for single-project mode.
- Helper: `WorkspaceStore.workspaces(for projectId: UUID) -> [Workspace]` filters `workspaces` for a given project (used by all-projects rendering).
- `WorkspaceStore.grouped()` keeps current single-project behavior; new `WorkspaceStore.grouped(projectId:)` returns lifecycle groupings for a specific project (used in all-projects "Group by status" mode).
- Mode switching triggers a reload (`load(projectId:)` vs. `loadAll()`).

### Lifecycle dot

- Update `WorkspaceRow` to accept `showLifecycleDot: Bool` (default `false`).
- When `true`: prepend a 6pt circle, color by state:
  - `inProgress` → blue
  - `inReview` → orange
  - `done` → green
  - `backlog` → gray
  - `cancelled` → red (dim)
- Used in all-projects flat mode; not shown in lifecycle-grouped sections (the section header conveys state).

---

## Feature 3 — Settings entry

`SettingsSheet` gains a "Sidebar" section:

```
Sidebar
  Layout: [Single project (grouped by status)  ▾]
                 - Single project (grouped by status)
                 - All projects (collapsible)
```

Bound to `appStore.sidebarMode`. On change, `appStore` writes to `UserDefaults` and triggers `WorkspaceStore` to reload using the appropriate loader.

---

## Architecture summary

New files:
- `Sources/MultiharnessCore/Worktree/RandomName.swift` — adjective/noun lists + `generate()`.

Modified files:
- `Sources/MultiharnessClient/Models/Models.swift` — add `SidebarMode` enum.
- `Sources/MultiharnessCore/Stores/AppStore.swift` — add `sidebarMode` (UserDefaults-backed).
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — `quickCreate(project:)`, `loadAll()`, `workspaces(for:)`, `grouped(projectId:)`.
- `Sources/Multiharness/Views/RootView.swift` — branch sidebar by `sidebarMode`; thread quick-create button into project picker header.
- `Sources/Multiharness/Views/WorkspaceSidebar.swift` — accept `showLifecycleDot`; new `AllProjectsSidebar` view (or section in same file) rendering disclosure groups.
- `Sources/Multiharness/Views/Sheets.swift` (or wherever `SettingsSheet` lives) — add Sidebar section.

UserDefaults keys (all `String`):
- `MultiharnessSidebarMode` → `"singleProject" | "allProjects"`
- `MultiharnessProjectExpanded.<projectId>` → `Bool`
- `MultiharnessProjectGroupByStatus.<projectId>` → `Bool`

---

## Edge cases

- **No projects**: all-projects mode shows the existing `ContentUnavailableView("Add a project…")`.
- **Project with zero workspaces**: disclosure group still expanded by default; under the header, render a small "No workspaces yet" caption alongside the always-active `+` button.
- **No providers configured**: `+` disabled, tooltip "Add a provider in Settings".
- **Name collision after 5 retries**: append `-2`, `-3`, … to the last generated name until unique.
- **Mode switch with a workspace selected**: keep `selectedWorkspaceId` if that workspace is still loaded after the reload; otherwise clear it.
- **Project deleted while expanded in all-projects mode**: corresponding `MultiharnessProjectExpanded.<id>` key becomes stale but harmless; can be cleaned up opportunistically when projects are listed.

---

## Out of scope

- Drag-to-reorder projects
- Per-project color/icon customization
- Cross-project workspace search
- Inline rename of workspaces from the sidebar
- Migrating existing single-project users automatically into all-projects mode

---

## Testing notes

- Unit test: `RandomName.generate()` always returns `<adjective>-<noun>` matching the expected pattern; never empty.
- Unit test: `WorkspaceStore.quickCreate` inherits from selected workspace when present, falls back to project defaults otherwise.
- Unit test: collision retry path produces a unique slug given a stubbed `RandomName`.
- Manual: switch sidebar modes; verify expansion state and group-by-status toggles persist across app relaunch.
- Manual: quick-create with and without a selected workspace; verify provider/model match expectations.
- Manual: in all-projects mode, selecting a workspace from a non-active project switches `selectedProjectId` correctly.

# Workspace activity & unseen indicators

**Date:** 2026-04-29
**Branch:** `jerednel/sidebar-indicators`

## Goal

Make it visually obvious in the workspace list which agents are currently working and which have produced new output the user hasn't yet seen.

- A small **spinner** appears on a workspace row while its agent is streaming.
- A small **blue "unseen" dot** appears on a workspace row when the latest assistant message is newer than the last time the user viewed that workspace.

This applies to both the macOS sidebar (`WorkspaceSidebar` / `AllProjectsSidebar`) and the iOS workspaces list (`WorkspacesView`).

## Visual design

For each workspace row, in the trailing edge:

- **Streaming:** a 12pt `ProgressView` (small, indeterminate, accent color). The existing lifecycle dot keeps its current position.
- **Else, unseen:** a ~7pt circle in `Color.accentColor`, same circle style as the existing lifecycle dot.
- **Else:** nothing extra.

The two new states are mutually exclusive — if a workspace is streaming we show the spinner, not the dot. The pre-existing lifecycle dot is unaffected and continues to render alongside.

## Data model

Add `last_viewed_at INTEGER NULL` to the `workspaces` table via a new appended migration.

```sql
ALTER TABLE workspaces ADD COLUMN last_viewed_at INTEGER;
UPDATE workspaces SET last_viewed_at = CAST(strftime('%s','now') AS INTEGER) * 1000;
```

Backfilling all existing rows to "now" avoids a sudden flood of dots on the first launch after upgrade.

The Swift `Workspace` struct (in `Sources/MultiharnessClient/Models/Models.swift`) gains `lastViewedAt: Date?`, threaded through `PersistenceService` reads/writes.

## Computing `unseen`

A workspace is **unseen** iff:

- there exists at least one assistant message in `<dataDir>/workspaces/<id>/messages.jsonl`, AND
- the timestamp of the latest assistant message is strictly greater than `last_viewed_at` (NULL `last_viewed_at` counts as `0`, but the migration backfill means existing rows start at "now").

The sidecar's `DataReader` already reads `messages.jsonl` to serve `remote.history`. We extend it with a small in-memory `Map<workspaceId, lastAssistantAt: number>` cache, populated lazily on first read of a workspace and updated whenever a new assistant turn is appended (driven by `agent_end` events flowing through `AgentRegistry`).

## Computing `isStreaming`

- **Mac:** `AgentStore.isStreaming` already exists per-workspace, set true on `agent_start` and false on `agent_end`. `AgentRegistryStore` exposes a per-workspace lookup. Bind it into `WorkspaceRow`.
- **iOS:** add `isStreaming: Bool` to `RemoteWorkspace`. The sidecar's `AgentRegistry` knows live sessions; it tracks an in-memory `Set<workspaceId>` of currently-streaming workspaces and includes `isStreaming` in `remote.workspaces` responses.

## Marking as viewed

- **Mac:** when `WorkspaceStore.selectedWorkspaceId` becomes a workspace id (including selection changes), call `WorkspacesRepository.markViewed(workspaceId)` which writes `last_viewed_at = now()`. While a workspace is currently selected and an `agent_end` event arrives for it, also re-apply `markViewed` so no dot appears for the workspace the user is actively looking at.
- **iOS:** when the user navigates into a workspace's detail view (`onAppear` of the detail), call a new relayed method `workspace.markViewed { workspaceId } → {}`. The Mac's `RemoteHandlers` calls the same `markViewed` repository method.

## Wire protocol additions

`RemoteWorkspace` gains two computed flags, both filled in by the sidecar:

```ts
interface RemoteWorkspace {
  // ...existing fields...
  isStreaming: boolean;
  unseen: boolean;
}
```

New server-pushed event so iOS doesn't need to poll:

```jsonc
{
  "event": "workspace.activity",
  "params": {
    "workspaceId": "...",
    "isStreaming": false,
    "unseen": true
  }
}
```

Emitted whenever either flag flips for a workspace: on `agent_start` (streaming → true), on `agent_end` (streaming → false, unseen recomputed), and on `workspace.markViewed` (unseen → false).

New relayed RPC:

```jsonc
{ "method": "workspace.markViewed", "params": { "workspaceId": "..." } }
```

The sidecar receives it, forwards via `Relay` to the Mac handler (consistent with the existing pattern for SQLite writes), and on success emits a `workspace.activity` event so other connected clients update.

## Files touched

**Persistence**
- `Sources/MultiharnessCore/Persistence/Migrations.swift` — append migration adding `last_viewed_at` column with backfill.
- `Sources/MultiharnessCore/Persistence/PersistenceService.swift` — read/write `lastViewedAt`; new `markWorkspaceViewed(_:)`.
- `Sources/MultiharnessClient/Models/Models.swift` — add `lastViewedAt: Date?` to `Workspace`.

**Mac stores & UI**
- `Sources/MultiharnessCore/Stores/WorkspaceStore.swift` — call `markViewed` on selection change.
- `Sources/MultiharnessCore/Stores/AgentRegistryStore.swift` — expose `isStreaming(forWorkspace:)` lookup; on `agent_end` for selected workspace, re-apply `markViewed`.
- `Sources/Multiharness/Views/WorkspaceSidebar.swift` — render spinner/dot in `WorkspaceRow`; same in `AllProjectsSidebar` rows.
- `Sources/Multiharness/RemoteHandlers.swift` — handle relayed `workspace.markViewed`.

**Sidecar**
- `sidecar/src/dataReader.ts` — track `lastAssistantAt` per workspace; helper to compute `unseen` for a row given `lastViewedAt`.
- `sidecar/src/agentRegistry.ts` — track streaming set; emit `workspace.activity` on transitions.
- `sidecar/src/methods.ts` — register relayed `workspace.markViewed`; enrich `remote.workspaces` rows with `isStreaming` and `unseen`.

**Shared client + iOS**
- `Sources/MultiharnessClient/RemoteModels.swift` — extend `RemoteWorkspace` with `isStreaming` and `unseen`.
- `Sources/MultiharnessClient/Sidecar/SidecarClient.swift` (or wherever events are dispatched) — handle `workspace.activity` event.
- `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift` — render spinner/dot; call `workspace.markViewed` from detail's `onAppear`.

**Tests**
- `Tests/MultiharnessTests/PersistenceTests.swift` — migration backfills `last_viewed_at`; `markViewed` writes timestamp.
- `Tests/MultiharnessTests/SidecarIntegrationTests.swift` — `remote.workspaces` returns correct `isStreaming` and `unseen`; `workspace.markViewed` clears `unseen`; `workspace.activity` fires on agent start/end.
- `sidecar/test/dataReader.test.ts` — `unseen` computation; cache invalidation when JSONL appends.

## Edge cases & decisions

- **Spinner + lifecycle dot coexist.** Confirmed: the spinner and the existing lifecycle status dot render together; we don't replace one with the other.
- **Currently-viewed workspace never shows a dot.** While a workspace is selected, both the initial `markViewed` (on selection) and the on-`agent_end` re-mark keep `last_viewed_at` ahead of any new assistant message.
- **Backfill avoids dot flood.** Existing rows get `last_viewed_at = now()` at migration time, so users don't see every prior workspace light up after upgrade.
- **Multi-client semantics.** `last_viewed_at` is global per workspace, not per client. Two iOS devices viewing the same Mac share viewed state — matches the user-level "I haven't seen this yet" intent.
- **No retroactive timestamps.** "Latest assistant message" comes from `messages.jsonl` events that already carry timestamps; no new timestamping logic needed.
- **Mac doesn't need `workspace.activity`.** It has direct `AgentStore` and SQLite access. The event is purely for remote clients (iOS).

## Out of scope

- Push notifications when a workspace finishes while the iOS app is backgrounded (would require APNs + a separate spec).
- Per-client unseen state (e.g., "seen on iPad but not Mac"). Single shared state is sufficient.
- Animating the dot's appearance, badge counts, or message-level read receipts.

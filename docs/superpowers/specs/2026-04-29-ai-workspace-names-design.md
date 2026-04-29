# AI-generated workspace names + manual rename

**Date:** 2026-04-29
**Status:** approved (live brainstorm)

## Goal

Replace the random adjective-noun name a workspace gets at quick-create with
a short title generated from the user's first prompt. Let the user override
that name (or any name) by right-clicking the workspace row.

Lifecycle:

- Quick-create → random `lucky-otter` style name (unchanged from today).
- First `agent.prompt` lands → sidecar generates a 2–6 word title with the
  workspace's own model, sanitises it, persists it via a new RPC. UI updates
  silently.
- User right-clicks → Mac sidebar shows **Rename…** which presents an inline
  field. Submit replaces the name.
- After either rename, the workspace is locked from further AI rename.

## Non-goals

- Renaming the SQLite `slug`, git branch, or worktree directory. The on-disk
  identity stays frozen at the original random value (decision: display-only
  rename). Branch names in PRs / git logs will look random; we accept that.
- iOS rename UI. iOS picks up the new display name passively via
  `remote.workspaces` and a new `workspace_updated` event.
- Choosing a separate "naming model" — the workspace's own model is used.
- Retrying a failed AI rename. One attempt per workspace, in-memory flag in
  the sidecar.

## Architecture

Three pieces:

1. **Schema + model.** New `name_source` column on `workspaces`
   (`'random' | 'named'`). `Workspace.nameSource: NameSource` in
   `Sources/MultiharnessClient/Models/Models.swift`. Persistence reads/writes
   the column. `WorkspaceStore.create(...)` (manual path) writes `'named'`;
   `quickCreate(...)` writes `'random'`. Existing rows default to `'random'`
   so they get upgraded on their next first prompt.
2. **`workspace.rename` RPC** (new method in `sidecar/src/methods.ts`).
   Relayed to the Mac handler in `Sources/Multiharness/RemoteHandlers.swift`.
   Mac persists `name = <new>`, `nameSource = .named`. After a successful
   relay response, the sidecar broadcasts a `workspace_updated` event to all
   connected clients so iOS picks up the change.
3. **AI naming in the sidecar.** `AgentSession` accepts `nameSource` at
   construction. On the first `prompt(message)` call where
   `nameSource === "random"`, fire-and-forget a one-off `complete()` (mirroring
   `conflictResolver.ts`) using the same provider/model the agent uses. On
   success → call `workspace.rename` internally (via the sidecar's own
   dispatcher) to apply the title. Flip an in-memory `aiRenameAttempted`
   flag so we don't pay for a retry.

## Data flow

### AI rename (after first prompt)

```
client → sidecar:    agent.prompt { workspaceId, message }
sidecar:             AgentSession.prompt(message)
                     -> agent.prompt(message)        (normal path, async)
                     -> if nameSource == "random" && !attempted:
                          attempted = true
                          (async) generateNameAndApply(workspaceId, message)
                            -> complete(model, systemPrompt, message, maxTokens=32)
                            -> sanitize(title)
                            -> dispatcher.invoke("workspace.rename", { workspaceId, name })
                                 -> relay.dispatch("workspace.rename", ...)
                                      -> Mac persists, returns ok
                            -> sink("", { type: "workspace_updated", workspaceId, name, nameSource: "named" })
all clients ←        workspace_updated event
                     iOS: ConnectionStore mutates its workspace cache
                     Mac: WorkspaceStore already has it (updated by relay handler)
```

### Manual rename (Mac right-click)

```
Mac UI →             "Rename…" → inline TextField → Enter
Mac:                 client.call("workspace.rename", { workspaceId, name })
sidecar:             relay.dispatch("workspace.rename", ...)
                     -> Mac handler updates DB + WorkspaceStore
                     -> returns ok
sidecar:             sink("", { type: "workspace_updated", ... })
iOS ←                cache update
```

The Mac is both caller and handler in the manual case — fine, it mirrors the
shape of `workspace.create` today (Mac → sidecar → Mac), so we don't invent
a new pattern.

## Components

### Schema migration (Migrations.swift)

Append to `Migrations.all`:

```sql
ALTER TABLE workspaces ADD COLUMN name_source TEXT NOT NULL DEFAULT 'random';
```

### `NameSource` enum + Workspace field

```swift
public enum NameSource: String, Codable, Sendable, Equatable {
    case random
    case named
}

// Workspace gains:
public var nameSource: NameSource    // default .random
```

`Workspace.init(...)` gets a `nameSource: NameSource = .random` param at the
end so existing call sites compile.

### Persistence

`PersistenceService.upsertWorkspace` and `listWorkspaces` add the column to
the INSERT/UPDATE/SELECT lists.

### WorkspaceStore

- `create(...)` (manual path, user typed the name): pass `nameSource: .named`
  when constructing the `Workspace`.
- `quickCreate(...)` (random name path): pass `nameSource: .random`.
- New `rename(_ ws: Workspace, to newName: String)` method that updates
  `name` + `nameSource = .named` and persists. Used by the Mac relay handler.

### Sidecar — `agent.create` + `AgentSession`

`agent.create` payload gains an optional `nameSource: "random" | "named"`
(defaults to `"named"` for safety — if a caller doesn't pass it, no AI
rename ever fires). Mac's `AppStore.createAgentSession` includes
`workspace.nameSource.rawValue`.

`AgentSessionOptions` gains `nameSource: "random" | "named"`. Session keeps
two booleans: `aiRenameEligible` (true iff `nameSource === "random"`) and
`aiRenameAttempted` (init false). On first `prompt(message)`:

```ts
if (this.aiRenameEligible && !this.aiRenameAttempted) {
  this.aiRenameAttempted = true;
  void generateAndApplyName(...).catch((err) =>
    log.warn("ai workspace rename failed", { workspaceId, err: String(err) })
  );
}
await this.agent.prompt(message);
```

### `generateAndApplyName`

New file `sidecar/src/workspaceNamer.ts`. Mirrors `conflictResolver.ts`:

```ts
const SYSTEM = `You name software work-in-progress. Given the user's first instruction, return a 2–6 word title in Title Case, no punctuation, no quotes, no trailing period. Just the title. ≤40 chars.`;

export async function generateWorkspaceName(args: {
  providerConfig: ProviderConfig;
  oauthStore?: OAuthStore;
  message: string;
  signal?: AbortSignal;
}, completeFn = complete): Promise<string | null> {
  const apiKey = await resolveApiKey(args.providerConfig, args.oauthStore);
  const model = buildModel(args.providerConfig);
  const timeoutSignal = AbortSignal.timeout(20_000);
  const sig = args.signal ? AbortSignal.any([args.signal, timeoutSignal]) : timeoutSignal;
  const result = await completeFn(model as any, {
    systemPrompt: SYSTEM,
    messages: [{ role: "user", content: [{ type: "text", text: args.message }], timestamp: Date.now() }],
  }, { apiKey, signal: sig, maxTokens: 64 });
  return sanitize(extractText(result));
}

function sanitize(raw: string): string | null {
  let s = raw.trim();
  // Strip wrapping quotes/backticks
  s = s.replace(/^["'`*_]+/, "").replace(/["'`*_]+$/, "");
  // Collapse whitespace, strip newlines
  s = s.replace(/\s+/g, " ").trim();
  // Drop trailing period
  s = s.replace(/\.$/, "");
  if (!s) return null;
  if (s.length > 40) s = s.slice(0, 40).trim();
  return s || null;
}
```

`AgentSession` calls this and, on a non-null result, invokes
`workspace.rename` through the sidecar's dispatcher (it has a reference to
the `Dispatcher` for this purpose — passed as a new `AgentSessionOptions`
field).

### `workspace.rename` RPC (methods.ts)

Add to the relayed-methods loop:

```ts
for (const m of [
  "workspace.create",
  "workspace.rename",        // new
  "project.scan",
  "project.create",
  "models.listForProvider",
  "fs.list",
]) { ... }
```

After a successful relay response, the dispatcher (or a thin wrapper) emits
`workspace_updated`. Cleanest: the Mac handler returns
`{ ok: true, workspaceId, name, nameSource: "named" }`, and a tiny wrapper
around the relay call in `methods.ts` for `workspace.rename` specifically
does:

```ts
d.register("workspace.rename", async (params) => {
  const result = await relay.dispatch("workspace.rename", params);
  if (result && typeof result === "object") {
    const r = result as Record<string, unknown>;
    sink("", {
      type: "workspace_updated",
      workspaceId: r.workspaceId,
      name: r.name,
      nameSource: r.nameSource,
    });
  }
  return result;
});
```

(So `workspace.rename` is registered explicitly — not in the loop — to get
this side effect.)

### Mac relay handler (RemoteHandlers.swift)

```swift
await relay.register(method: "workspace.rename") { params in
    try await Self.workspaceRename(
        params: params, env: env, workspaceStore: workspaceStore
    )
}
```

```swift
private static func workspaceRename(
    params: [String: Any],
    env: AppEnvironment,
    workspaceStore: WorkspaceStore
) async throws -> Any? {
    guard let idStr = params["workspaceId"] as? String,
          let id = UUID(uuidString: idStr) else {
        throw RemoteError.bad("workspaceId required (UUID)")
    }
    guard let raw = params["name"] as? String else {
        throw RemoteError.bad("name required")
    }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 80 else {
        throw RemoteError.bad("name must be 1–80 chars")
    }
    guard let ws = workspaceStore.workspaces.first(where: { $0.id == id }) else {
        throw RemoteError.bad("workspace not found")
    }
    workspaceStore.rename(ws, to: trimmed)
    return [
        "ok": true,
        "workspaceId": id.uuidString,
        "name": trimmed,
        "nameSource": NameSource.named.rawValue,
    ] as [String: Any]
}
```

### Mac UI (WorkspaceSidebar.swift)

Add to `workspaceContextMenu`:

```swift
Button("Rename…") {
    pendingRename = ws
}
Divider()
```

Use a sheet (or inline alert with TextField on macOS 14) to capture the
new name. Calls `WorkspaceStore.requestRename(...)` which goes through the
sidecar via `client.call("workspace.rename", ...)`. On success the relay
handler updates the store; the sheet dismisses on the same tick because
the rename closure awaits the call.

Keep both call sites (the top-level `WorkspaceSidebar` and the
`AllProjectsSidebar`/`ProjectDisclosure` variant) in sync — both have a
context menu builder.

### iOS event handling (ConnectionStore.swift)

In `controlClient(_:didReceiveEvent:)`, branch on `event.type`:

```swift
if event.type == "workspace_updated" {
    Task { @MainActor in self.applyWorkspaceUpdate(event.payload) }
    return
}
// existing per-agent dispatch
```

`applyWorkspaceUpdate` mutates the local `workspaces` array by id —
updates `name` (and `nameSource` if we choose to mirror it on iOS, optional).

## Failure modes

- **Rename RPC fails (Mac handler missing, name invalid, etc.)** — sidecar
  logs a warning. UI for manual rename surfaces the error inline; AI rename
  silently keeps the random name.
- **`complete()` fails or times out (20s)** — sidecar logs warn, leaves
  `nameSource = "random"` in DB but flips `aiRenameAttempted = true` in
  memory so we don't loop. Next sidecar restart resets the in-memory flag,
  effectively giving one retry per process lifetime — acceptable.
- **Sanitised name empty** — give up silently.
- **Concurrent first prompts** — `aiRenameAttempted` is set synchronously
  before the async generation begins, so a second prompt won't double-fire.

## Testing

- **bun test** `workspaceNamer.test.ts` — sanitisation cases (quotes,
  trailing period, multi-line, > 40 chars, empty); model returning empty
  text.
- **bun test** `agentSession.namer.test.ts` — first prompt with
  `nameSource = "random"` triggers generator exactly once; second prompt
  doesn't; first prompt with `"named"` doesn't.
- **swift test** — migration v4 applies cleanly; round-trip a Workspace
  with `nameSource = .named` through `upsertWorkspace` /
  `listWorkspaces`.
- Manual end-to-end: build app, quick-create a workspace, send a prompt
  ("Add a dark mode toggle to the settings screen"), watch the sidebar
  entry rename within ~2s. Right-click → Rename… → type "Custom name" →
  Enter, observe instant update + iOS picks up the change.

## Open questions

None at brainstorm sign-off. Backfill behaviour (existing rows default
`name_source = 'random'`) is intentional — gives existing workspaces a
free upgrade on their next first prompt. If we later regret that, a
follow-up migration can flip them to `'named'`.

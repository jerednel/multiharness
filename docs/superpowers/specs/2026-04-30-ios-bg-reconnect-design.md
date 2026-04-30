# iOS background reconnect — design

## Problem

When the user switches away from the iOS Multiharness app and returns,
the WebSocket session to the Mac sidecar is dead: the workspaces screen
shows an orange yield sign with "Couldn't connect" (rendered by
`WorkspacesView.errorView` in `ios/Sources/MultiharnessIOS/Views/WorkspacesView.swift:139`),
and the user must tap **Retry** to reconnect.

Root cause:

- The iOS app has no `ScenePhase` observer or `UIApplication`
  lifecycle hooks. `App.swift` and `RootView.swift` are bare.
- iOS suspends the app within ~30 s of backgrounding. The
  `URLSessionWebSocketTask` socket is torn down by the OS, and on
  return the next RPC fails with `ENOTCONN`.
- `ControlClient.controlClientDidDisconnect(_:error:)` flips
  `ConnectionStore.state` from `.connected` to `.error(...)`, which the
  UI renders as the yield sign + Retry button.

The user's goal: returning to the app should look unchanged. They
should not see a yield sign, an error, or a "Connecting…" indicator
for short app-switches; the reconnect should be invisible.

## Constraints we cannot remove

- iOS will suspend the process. We cannot keep the socket open across
  arbitrary background durations. The most we can do is (a) bridge
  very brief excursions with a `UIApplication.beginBackgroundTask` so
  the socket may survive a few seconds, and (b) reconnect transparently
  on return.
- The Mac persists conversation state (`messages.jsonl` per workspace,
  SQLite for project/workspace metadata). On reconnect, iOS already
  rehydrates via `remote.workspaces` and `remote.history` — no new
  resume protocol is needed.

## Design

We add two pieces of state to `ConnectionStore`
(`ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift`) and one
lifecycle observer in `App.swift`. No protocol changes; no sidecar
changes.

### 1. App-lifecycle observer

`App.swift` adopts `@Environment(\.scenePhase)` and forwards
transitions to the active `ConnectionStore`:

- `.active` → `connection.didEnterForeground()`
- `.background` → `connection.didEnterBackground()`
- `.inactive` is ignored (transient, e.g., notification banner).

Because the active connection lives behind `PairingStore.connection`,
we observe `scenePhase` at the `App` level and call through
`pairing.connection?.didEnterForeground()` / `didEnterBackground()`.
Pairings without an active connection (the `PairingView` screen) are
unaffected.

### 2. Backgrounded mode in `ConnectionStore`

Add a private `isBackgrounded: Bool` flag and a
`backgroundTaskID: UIBackgroundTaskIdentifier?`.

`didEnterBackground()`:

1. Set `isBackgrounded = true`.
2. Begin a `UIApplication.shared.beginBackgroundTask(withName:
   "multiharness-ws-close")`. Store the identifier.
3. Call `client.disconnect()` synchronously. (`ControlClient.disconnect`
   sends the WS close frame and cancels the listener; this is fast.)
4. **Do not change `state`**. The user-visible state stays whatever it
   was (typically `.connected`). The yield sign never appears.
5. End the background task once disconnect completes. We register the
   standard `expirationHandler:` so the OS can reclaim the task if our
   own end-call doesn't fire first.

We override the disconnect-event suppression in
`controlClientDidDisconnect(_:error:)`: if `isBackgrounded == true`,
**do not** transition to `.error`. Just record the underlying client
state and return.

### 3. Foregrounded reconnect with 1-second UI suppression

Add a private `pendingReconnectTimer: Task<Void, Never>?`.

`didEnterForeground()`:

1. Set `isBackgrounded = false`.
2. Because `didEnterBackground()` always calls `client.disconnect()`,
   the socket is closed by the time we get here. Call
   `client.connect()` unconditionally **without** changing `state`.
   The UI continues to show the previous state (typically
   `.connected`).
3. Schedule `pendingReconnectTimer`: a `Task` that sleeps 1 000 ms
   then, on the main actor, checks whether
   `controlClientDidConnect(_:)` has fired in the meantime. If not,
   flip `state = .connecting` so the user sees the "Connecting…"
   view from this point on. (We track the "connected since
   reconnect started" condition with a private flag set by the
   delegate callback.)

Reconcile with the existing delegate callbacks:

- `controlClientDidConnect(_:)` cancels `pendingReconnectTimer` and
  sets `state = .connected` as today. If we beat the 1 s window, the
  user never saw a UI change.
- `controlClientDidDisconnect(_:error:)` (after we've foregrounded —
  i.e., `isBackgrounded == false`) cancels the timer and sets
  `state = .error(...)` as today. Genuine failures still surface; only
  the *first second* of a foreground-driven reconnect is visually
  suppressed.

### 4. Existing paths preserved

- `connect()` (called from the **Retry** button at
  `WorkspacesView.swift:147`) keeps its current behavior: it sets
  `state = .connecting` immediately so the user sees feedback.
- `disconnect()` (called from `PairingStore` on unpair) keeps its
  current behavior: sets `state = .disconnected`.
- The lifecycle methods are additive; nothing else changes.

## State-machine summary

| Trigger | `isBackgrounded` | Action | UI change |
|---|---|---|---|
| `.background` | true | `client.disconnect()`, begin BG task | none |
| Disconnect callback during BG | true | swallow | none |
| `.active` | false | `client.connect()`, arm 1 s timer | none for 1 s |
| Connected within 1 s window | false | cancel timer, `state = .connected` | none |
| 1 s elapses, still not connected | false | `state = .connecting` | spinner appears |
| Disconnect after 1 s window | false | `state = .error(...)` | yield sign |
| Retry button | false | `state = .connecting`, `client.connect()` | spinner appears |

## Out of scope

- Heartbeat / ping. Not needed once `.active` triggers an immediate
  reconnect: the next RPC after foregrounding is the de-facto health
  check, and a dead socket is replaced before the user notices.
- Cross-process/Push-driven background updates. We do not promise
  delivery of agent output while the app is suspended; on return the
  history fetch (`remote.history`) reconciles.
- Any sidecar-side change. The sidecar already serves
  `remote.workspaces` / `remote.history` for rehydration.

## Test plan

Manual (the iOS app cannot be unit-tested for `ScenePhase` cleanly):

1. Pair, open a workspace, verify `.connected`.
2. Switch to another app for ~3 s, return. Expected: no yield sign,
   no spinner, list still rendered.
3. Switch to another app for ~30 s (long enough that iOS will have
   torn down the socket), return. Expected: no yield sign; if
   reconnect takes >1 s a spinner appears, then list returns.
4. Switch away with Wi-Fi off on the iPhone. Return. Expected: a
   spinner appears after ~1 s; toggling Wi-Fi back on completes the
   reconnect, and we land on `.connected`. If reconnect ultimately
   fails, the existing yield-sign + Retry path still works.
5. Tap **Retry** while in `.error`. Expected: behaves exactly as
   today — immediate `.connecting` spinner, then `.connected` or
   `.error`.

If we have appetite, add a small unit test on `ConnectionStore` that
exercises `didEnterBackground` / `didEnterForeground` with a fake
`ControlClient` (the existing tests don't cover `ConnectionStore` yet,
so this is greenfield).

## Risks

- **Race between `disconnect()` and OS suspension.** We open a
  background task to give the close frame time to flush. Worst case:
  the close frame is dropped and the sidecar logs a stale connection
  for a few seconds; not a correctness issue.
- **`controlClientDidDisconnect` arriving on background queue while
  we're transitioning to `.background`.** The delegate already hops
  to `@MainActor`, so the order is well-defined. The
  `isBackgrounded` flag is set on `.background` *before* calling
  `client.disconnect()`, so the resulting disconnect callback sees
  the flag and is suppressed.
- **Pairing changes while backgrounded.** If the user pairs with a
  different Mac and immediately backgrounds, the new connection's
  `ConnectionStore` should still receive the `.background`
  transition. We forward through `PairingStore.connection` which
  always points to the active store.

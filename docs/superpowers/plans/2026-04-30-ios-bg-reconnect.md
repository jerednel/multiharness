# iOS background reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make returning to the iOS app after switching apps look unchanged — disconnect-on-background, reconnect-on-foreground, suppress the "Connecting…"/yield-sign UI unless reconnect takes more than 1 second.

**Architecture:** Add lifecycle methods to `ConnectionStore` and wire them up to a `ScenePhase` observer in `App.swift`. While "backgrounded," the existing `controlClientDidDisconnect` → `.error` path is suppressed. On foreground, kick off `client.connect()` without changing `state`; arm a 1 s timer that flips `state` to `.connecting` only if reconnect hasn't completed by then. No protocol or sidecar changes.

**Tech Stack:** SwiftUI (`ScenePhase`), UIKit (`UIApplication.beginBackgroundTask`), `URLSessionWebSocketTask`, the existing `ControlClient`.

**Spec:** `docs/superpowers/specs/2026-04-30-ios-bg-reconnect-design.md`

**Note on tests:** The iOS target has no XCTest test target (`ios/project.yml:30` has `testTargets: []`). Adding a test target plus a `ControlClientProtocol` seam would be more scaffolding than the change itself. Verification is manual against the checklist in Task 3. The spec acknowledges this.

---

### Task 1: Add lifecycle hooks to `ConnectionStore`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift` (add import, properties, two public methods, and adjust two delegate callbacks)

**Why this is one task:** the new state, the new methods, and the delegate-callback adjustments must land together — partial application breaks invariants (e.g., backgrounded mode without delegate suppression would still flip the UI to `.error`).

- [ ] **Step 1: Add `import UIKit`**

`ConnectionStore.swift` currently imports `Foundation`, `Observation`, `MultiharnessClient` (lines 1–3). Add `import UIKit` so we can reference `UIApplication`, `UIBackgroundTaskIdentifier`, and `.invalid`.

```swift
import Foundation
import Observation
import UIKit
import MultiharnessClient
```

- [ ] **Step 2: Add private lifecycle state**

Insert after the existing `private let client: ControlClient` declaration (currently `ConnectionStore.swift:26`):

```swift
    private let client: ControlClient

    // MARK: App-lifecycle reconnect state

    /// True between `didEnterBackground()` and `didEnterForeground()`.
    /// While true, we swallow disconnect callbacks so the UI doesn't
    /// flip to `.error`.
    private var isBackgrounded: Bool = false

    /// Timer that flips `state` to `.connecting` if a foreground
    /// reconnect hasn't completed within 1 s.
    private var pendingReconnectTimer: Task<Void, Never>?

    /// Background task identifier opened in `didEnterBackground()` to
    /// give the WS close frame a chance to flush before iOS suspends us.
    private var bgTaskID: UIBackgroundTaskIdentifier = .invalid
```

- [ ] **Step 3: Add `didEnterBackground()` and `didEnterForeground()`**

Insert immediately after the existing `disconnect()` method (currently `ConnectionStore.swift:41-44`):

```swift
    public func disconnect() {
        client.disconnect()
        state = .disconnected
    }

    /// Called from `App.body.onChange(of: scenePhase)` when the scene
    /// transitions to `.background`. Closes the socket without
    /// changing the user-visible `state`.
    public func didEnterBackground() {
        guard !isBackgrounded else { return }
        isBackgrounded = true

        pendingReconnectTimer?.cancel()
        pendingReconnectTimer = nil

        // Begin a brief background task so the close frame can flush
        // before iOS suspends us. The expiration handler is the OS's
        // way of saying "time's up" — we just clean up the identifier.
        bgTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "multiharness-ws-close"
        ) { [weak self] in
            guard let self else { return }
            if self.bgTaskID != .invalid {
                UIApplication.shared.endBackgroundTask(self.bgTaskID)
                self.bgTaskID = .invalid
            }
        }

        client.disconnect()
        // Note: deliberately NOT setting `state = .disconnected`. The
        // user-visible state stays whatever it was (typically
        // `.connected`); the resulting `controlClientDidDisconnect`
        // callback is suppressed while `isBackgrounded == true`.

        if bgTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(bgTaskID)
            bgTaskID = .invalid
        }
    }

    /// Called from `App.body.onChange(of: scenePhase)` when the scene
    /// transitions to `.active`. Starts a fresh socket without
    /// flipping the UI to `.connecting` for the first 1 s.
    public func didEnterForeground() {
        guard isBackgrounded else { return }
        isBackgrounded = false

        // Because we always closed in `didEnterBackground()`, we
        // always need a fresh socket here. Do NOT change `state` — the
        // UI continues to render whatever it had (typically
        // `.connected`).
        client.connect()

        pendingReconnectTimer?.cancel()
        pendingReconnectTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // If `controlClientDidConnect(_:)` already fired, state
                // is `.connected` and we leave it alone. Otherwise the
                // user has been staring at a stale "connected" view
                // for 1 s — show the spinner from here on.
                if self.state != .connected {
                    self.state = .connecting
                }
            }
        }
    }
```

- [ ] **Step 4: Suppress disconnect callback while backgrounded; cancel timer on connect**

The existing delegate methods are at `ConnectionStore.swift:318-329`. Replace both:

```swift
    nonisolated public func controlClientDidConnect(_ client: ControlClient) {
        Task { @MainActor in
            self.pendingReconnectTimer?.cancel()
            self.pendingReconnectTimer = nil
            self.state = .connected
            await self.refreshWorkspaces()
        }
    }

    nonisolated public func controlClientDidDisconnect(_ client: ControlClient, error: Error?) {
        Task { @MainActor in
            // While the app is backgrounded, the WS close (initiated
            // by `didEnterBackground()`) fires this callback. Swallow
            // it — `state` should not flip to `.error`.
            if self.isBackgrounded { return }
            self.pendingReconnectTimer?.cancel()
            self.pendingReconnectTimer = nil
            self.state = .error(error.map { String(describing: $0) } ?? "disconnected")
        }
    }
```

- [ ] **Step 5: Build the iOS target to verify it compiles**

Run from the project root:

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds. The script runs `xcodegen generate` (no-op since `project.yml` is unchanged) and `xcodebuild` for the iOS Simulator. If you see "Missing package product 'MultiharnessClient'", run `MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh`.

- [ ] **Step 6: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Stores/ConnectionStore.swift
git commit -m "ConnectionStore: lifecycle hooks for silent bg reconnect

Adds didEnterBackground / didEnterForeground that close the WS on
background entry and reopen on foreground without flipping the UI to
\".error\" or \".connecting\" — unless reconnect takes longer than
1 second, after which the spinner appears.

The existing connect()/disconnect()/Retry paths are unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wire `ScenePhase` observer in `App.swift`

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/App.swift` (full rewrite, 12 lines → ~26 lines)

- [ ] **Step 1: Replace `App.swift`**

The current file is 12 lines (verified at `ios/Sources/MultiharnessIOS/App.swift:1-12`):

```swift
import SwiftUI

@main
struct MultiharnessIOSApp: App {
    @State private var pairing = PairingStore()

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing)
        }
    }
}
```

Replace with:

```swift
import SwiftUI

@main
struct MultiharnessIOSApp: App {
    @State private var pairing = PairingStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(pairing: pairing)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                pairing.connection?.didEnterForeground()
            case .background:
                pairing.connection?.didEnterBackground()
            case .inactive:
                // Transient (e.g., notification banner). Ignore.
                break
            @unknown default:
                break
            }
        }
    }
}
```

`onChange(of:)` does not fire for the initial value, so initial pairing/connect (handled by `PairingStore.init()` at `PairingStore.swift:35-44`) is unaffected. Switching pairings while in foreground also runs through `PairingStore.connect(to:)`, which builds a fresh `ConnectionStore` whose `isBackgrounded` defaults to `false` — so the next background transition arms suppression on the new store.

- [ ] **Step 2: Build the iOS target**

```bash
bash scripts/build-ios.sh
```

Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Sources/MultiharnessIOS/App.swift
git commit -m "App: forward ScenePhase to ConnectionStore lifecycle hooks

Drives the new didEnterBackground / didEnterForeground methods so the
WS reconnect on app-switch is invisible.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Manual verification on the simulator (or a real device)

**Files:** none (verification only)

The simulator can simulate backgrounding via Cmd+Shift+H (home) and tapping the Multiharness icon to return. Real-device testing is more representative because the simulator's networking is more lenient about idle sockets — if you have an iPhone paired to the dev Mac, prefer that.

- [ ] **Step 1: Boot the app and confirm the baseline**

```bash
MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh
```

This boots a sim, installs, and launches. The Mac sidecar must already be running with Remote access enabled (Settings → Remote access in the Mac app). Pair via the QR code or pasted `mh://...` string. Open a workspace.

Verify: `state == .connected` (no yield sign, no spinner, workspace list visible).

- [ ] **Step 2: Quick app-switch (≤3 seconds)**

Press Cmd+Shift+H to send the iOS app to the home screen. Wait ~2 seconds. Tap the Multiharness icon to return.

Expected:
- No yield sign appears.
- No "Connecting…" spinner appears.
- The workspace list is rendered exactly as before.
- A subsequent agent prompt succeeds (proving the socket really did reopen).

Failure modes to watch for:
- Yield sign flashes briefly → `controlClientDidDisconnect` is firing without `isBackgrounded` set. Re-check Task 1, Step 4.
- "Connecting…" spinner appears for a fraction of a second → `state` is being flipped to `.connecting` somewhere it shouldn't. Re-check Task 1, Step 3 (the comment about not setting `state`).

- [ ] **Step 3: Long app-switch (≥30 seconds)**

Switch to another app (e.g., Safari) and stay for at least 30 seconds so iOS actually suspends Multiharness and tears the socket down at the OS level. Return.

Expected:
- No yield sign.
- If reconnect completes in <1 s: no UI change at all.
- If reconnect is slow (e.g., on Tailscale over cellular): the "Connecting…" spinner appears at the 1-second mark and disappears once connected.
- A subsequent prompt succeeds.

- [ ] **Step 4: Network-down case**

Switch away with the iPhone's Wi-Fi off (Control Center). Wait long enough for the socket to definitely die. Return with Wi-Fi still off.

Expected:
- The "Connecting…" spinner appears at the 1-second mark.
- After the underlying `URLSessionWebSocketTask` reports failure, the existing path flips `state` to `.error("...")` — yield sign + Retry button appears, exactly as today.
- Toggle Wi-Fi back on; tap Retry. Expected: reconnects normally.

This proves the suppression doesn't hide *real* failures; it only hides the gap during a successful (or in-progress) reconnect.

- [ ] **Step 5: Retry button regression check**

While disconnected (e.g., Mac sidecar paused, or Wi-Fi off), force the app into `.error`. Tap Retry.

Expected:
- The "Connecting…" view appears immediately (not after 1 s) — this confirms the manual `connect()` path at `WorkspacesView.swift:147` still flips `state = .connecting` synchronously via `ConnectionStore.connect()` (`ConnectionStore.swift:36-39`), which the lifecycle changes did not touch.

- [ ] **Step 6: Pairing-while-backgrounded edge case (lower priority)**

Pair Mac A; open a workspace; background the app; on the Mac switch to a different sidecar instance (or unplug the network briefly); return to iOS. Tap **Macs** and switch to Mac B (re-pair if needed).

Expected: no crash, no orphan reconnect timer firing on the wrong store. The new `ConnectionStore` for Mac B has `isBackgrounded = false` and behaves like a fresh app launch.

- [ ] **Step 7: Commit a verification note (only if you found and fixed any bugs)**

If steps 1–6 all passed cleanly, no commit is needed for Task 3 — the work is done. If you needed a follow-up fix, commit it with a message describing the exact symptom and the fix.

---

## Self-review

**Spec coverage:**
- §1 Lifecycle observer → Task 2.
- §2 Backgrounded mode (isBackgrounded flag, beginBackgroundTask, suppression of disconnect → error) → Task 1, steps 2/3/4.
- §3 Foregrounded reconnect with 1 s suppression → Task 1, step 3 (`didEnterForeground` + timer); reconciled in step 4 (timer cancel on connect).
- §4 Existing paths preserved → Task 3, step 5 (Retry regression check).
- State-machine table rows → all covered by Tasks 1+2; verified by Task 3 steps.
- Test plan rows 1–5 in spec → Task 3 steps 1–5; spec's optional unit-test note → explicitly out-of-scope per plan header (no iOS test target).

**Placeholder scan:** none ("TBD", "TODO", "implement later" do not appear; all code blocks are complete; all commands have expected output).

**Type/name consistency:**
- `isBackgrounded`, `pendingReconnectTimer`, `bgTaskID`, `didEnterBackground()`, `didEnterForeground()` are referenced identically across Task 1 (definition), Task 1 step 4 (delegate suppression), and Task 2 (App.swift call sites).
- `ConnectionStore.State` cases (`.connected`, `.connecting`, `.error`, `.disconnected`) match the existing enum at `ConnectionStore.swift:11-16`.
- `ScenePhase` cases (`.active`, `.background`, `.inactive`) match SwiftUI's standard set; `@unknown default` covers future additions.

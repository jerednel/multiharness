# Agent completion sound

**Status:** spec
**Date:** 2026-05-01

## Goal

Play a short, airplane-style chime on the Mac whenever an agent finishes
responding, so the user can walk away from a workspace and still know when it's
ready for them. Sound is suppressed only when the user is already looking at
the finished workspace — i.e. when Multiharness is the frontmost app *and* the
finished workspace is the one currently selected in the sidebar. In every
other situation (Mac in the background, Multiharness frontmost but a different
workspace selected, app minimized, another desktop), the ding plays.

A single toggle in **Settings → Defaults** lets the user disable the sound.
Default is on.

## Non-goals

- iOS notifications. iOS already has its own notification model and remote
  pairing, and the focus rule here is Mac-window-specific.
- Per-workspace or per-project sound preferences. One global toggle.
- A volume slider, sound picker, or custom-sound option. The chime ships as a
  bundled, fixed asset.
- Persistent OS-level notifications (banners, dock badges, alerts). Sound only.
- Throttling or coalescing rapid completions. If two agents finish within 100ms
  the audible result is still a single recognizable chime; we accept the cut-off
  rather than build debounce machinery.

## Design

### 1. The chime asset

Bundle a short (~1 sec) two-tone airplane-style chime as
`Sources/Multiharness/Resources/agent-ding.wav`, sourced from a
royalty-free / CC0 source (Pixabay sounds or freesound.org). Source URL +
license recorded in `Sources/Multiharness/Resources/CREDITS.txt` so anyone
auditing the bundle can verify usage rights.

Wire the resource into the executable target in `Package.swift`:

```swift
.executableTarget(
    name: "Multiharness",
    dependencies: ["MultiharnessCore", "MultiharnessClient"],
    path: "Sources/Multiharness",
    resources: [.process("Resources")]
)
```

Constraints on the asset:

- WAV (PCM) or AIFF, 16-bit, mono or stereo, ≤2 seconds, ≤100 KB. Avoids any
  codec-handling surprises and keeps the .app bundle nearly the same size.
- License must be CC0 or equivalent (Pixabay license) — no attribution
  obligation in-app, attribution only in `CREDITS.txt`.

### 2. `CompletionSoundPlayer`

New file `Sources/Multiharness/Sound/CompletionSoundPlayer.swift`. It lives in
the executable target, not `MultiharnessCore`, because:

- The asset bundle (`Bundle.main`) is the executable's bundle. Loading it from
  the core library complicates `Bundle.module` resolution between SPM build
  contexts and the .app build, with no upside.
- The component is macOS-only by design, and the executable target is
  macOS-only.

```swift
import AppKit
import AVFoundation
import os

@MainActor
final class CompletionSoundPlayer {
    private let player: AVAudioPlayer?
    private let logger = Logger(subsystem: "com.multiharness", category: "sound")

    init(resourceName: String = "agent-ding", ext: String = "wav") {
        guard let url = Bundle.main.url(forResource: resourceName, withExtension: ext) else {
            logger.warning("CompletionSoundPlayer: resource \(resourceName).\(ext) not found in bundle")
            self.player = nil
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            self.player = p
        } catch {
            logger.warning("CompletionSoundPlayer: failed to load: \(String(describing: error))")
            self.player = nil
        }
    }

    func play() {
        guard let player else { return }
        // Re-trigger from the start; if a chime is mid-play we cut it off.
        player.currentTime = 0
        player.play()
    }
}
```

Notes:

- `AVAudioPlayer` over `NSSound` because it gives us `prepareToPlay`,
  `currentTime` reset, and is the standard modern audio API on macOS.
- Failure modes (missing asset, decode error) become a silent no-op: the
  feature degrades to "no sound" rather than crashing or dialoguing the user.
  The warning lands in the unified log (`os_log`) for diagnosis.

### 3. The decision: when to play

A pure function so it can be unit-tested without instantiating SwiftUI state:

```swift
struct CompletionSoundDecision {
    static func shouldPlay(
        enabled: Bool,
        appIsFrontmost: Bool,
        selectedWorkspaceId: UUID?,
        eventWorkspaceId: UUID
    ) -> Bool {
        guard enabled else { return false }
        if appIsFrontmost && selectedWorkspaceId == eventWorkspaceId {
            return false
        }
        return true
    }
}
```

This lives in `Sources/MultiharnessCore/Sound/CompletionSoundDecision.swift`,
not the executable target. Reason: it's a pure function with no AppKit/AVFoundation
dependency, and the test target depends on Core, not the executable. Keeping
the "decide" half in Core and the "play" half (`CompletionSoundPlayer`) in the
executable mirrors the pattern the rest of the app uses for UI-adjacent logic.

### 4. The settings toggle

A new boolean stored in `UserDefaults`, mirroring the existing `sidebarMode`
pattern in `AppStore` (`Sources/MultiharnessCore/Stores/AppStore.swift:14-20`).
UserDefaults — not the SQLite `settings` table — because:

- It's a Mac-app preference, not a cross-client/cross-process piece of state.
- iOS does not need or read it. The SQLite `settings` table is for things the
  sidecar or remote clients can also consume (e.g. global default provider).
- Lower ceremony — no migration, no `try`, no DB roundtrip on every
  `agent_end`.

```swift
public var playCompletionSound: Bool = true {
    didSet {
        guard oldValue != playCompletionSound else { return }
        UserDefaults.standard.set(playCompletionSound, forKey: Self.playCompletionSoundDefaultsKey)
    }
}
public static let playCompletionSoundDefaultsKey = "MultiharnessPlayCompletionSound"
```

Loaded in `AppStore.load()` alongside the existing `sidebarMode` rehydration.
Default `true` if the key has never been written. (`UserDefaults.bool(forKey:)`
returns `false` for an absent key, so we explicitly check
`object(forKey:) != nil` to distinguish "absent" from "user set false".)

### 5. The hook

Already established at `Sources/Multiharness/App.swift:175-182` in
`AgentRegistryStore.controlClient(_:didReceiveEvent:)`'s `agent_end` branch.
Extend it:

```swift
if event.type == "agent_end" {
    self.workspaceStore?.recordAssistantEnd(workspaceId: id)
    if self.workspaceStore?.selectedWorkspaceId == id {
        self.workspaceStore?.markViewed(id)
    }
    self.maybePlayCompletionSound(for: id)   // NEW
}
```

`AgentRegistryStore` gains:

- A `let completionSoundPlayer = CompletionSoundPlayer()` property,
  instantiated at `init` time so the asset is loaded once and decoded into
  memory ahead of the first agent finishing. This avoids first-play latency.
- A `private func maybePlayCompletionSound(for: UUID)` method that:
  1. Reads `appStore?.playCompletionSound` (default true if appStore is nil,
     which is impossible in practice but the closure-weak-ref dance benefits
     from a safe default).
  2. Reads `NSApp.isActive` (already on the main actor).
  3. Reads `workspaceStore?.selectedWorkspaceId`.
  4. Calls `CompletionSoundDecision.shouldPlay(...)` and, if true, calls
     `completionSoundPlayer.play()`.

The hook is on the main actor (the existing `Task { @MainActor in ... }`
already wraps this branch), so all reads are safe.

### 6. The settings UI

Add a "Notifications" subsection at the **top** of `DefaultsTab`
(`Sources/Multiharness/Views/Sheets.swift:520-597`), above the existing
"Default provider" content. A short divider between sections keeps the
existing content visually unchanged.

```swift
VStack(alignment: .leading, spacing: 12) {
    Text("Defaults").font(.title3).bold()

    // Notifications subsection — NEW
    VStack(alignment: .leading, spacing: 6) {
        Text("Notifications").font(.headline)
        Toggle("Play sound when an agent finishes responding",
               isOn: $appStore.playCompletionSound)
        Text("Quiet when this window is focused on the same workspace.")
            .font(.caption).foregroundStyle(.secondary)
    }
    Divider()

    // Existing default-provider section unchanged
    Text("Used when creating a workspace if the project has no default…")
    // ...
}
```

The caption explains the suppression rule in plain language so the user can
self-diagnose "why didn't it ding?" without reading source.

## Error handling, edge cases

- **Missing or corrupt audio asset** — `CompletionSoundPlayer.init` logs a
  warning and `play()` becomes a no-op. The user sees nothing; the feature
  silently degrades. (Discoverable via `log show --predicate 'subsystem == "com.multiharness"'`.)
- **Two completions in rapid succession** — the second `play()` call resets
  `currentTime = 0` and replays from the start, cutting off the first. Audible
  result: a single ding, possibly slightly truncated. Acceptable; alternatives
  (queueing, ignoring) add complexity for no real benefit.
- **App in the foreground, workspace A selected, agent in workspace A
  finishes** — the existing `markViewed(id)` already runs in this case, and
  the new sound logic suppresses the ding. Correct.
- **App in the foreground but minimized / on a different Space** —
  `NSApp.isActive` is false in both cases, so the ding plays. Correct.
- **Multiharness frontmost on workspace B, agent in workspace A finishes** —
  app active = true, but selected ≠ event workspace, so the ding plays.
  Correct.
- **No active workspace selected (`selectedWorkspaceId == nil`)** — app
  frontmost, no workspace selected, agent finishes anywhere. The selected-id
  comparison is false (`nil != UUID`), so the ding plays. This is the right
  call: the user is on the project-level view, not watching any specific
  agent.
- **OS-level "Do Not Disturb" / Focus mode** — out of scope. `AVAudioPlayer`
  bypasses the OS notification system entirely. If the user has the system
  muted, the chime is muted too (because system volume gates it), which is
  the expected behavior. We don't try to honor Focus.

## Test plan

### Unit tests (Mac)

New file `Tests/MultiharnessCoreTests/CompletionSoundDecisionTests.swift`,
covering `CompletionSoundDecision.shouldPlay` (which lives in
`MultiharnessCore`, see Design §3).

Test cases:

| enabled | appActive | selectedId       | eventId | expected |
|---------|-----------|------------------|---------|----------|
| false   | any       | any              | any     | false    |
| true    | true      | == eventId       | UUID-A  | false    |
| true    | true      | != eventId       | UUID-A  | true     |
| true    | true      | nil              | UUID-A  | true     |
| true    | false     | == eventId       | UUID-A  | true     |
| true    | false     | nil              | UUID-A  | true     |

### Build verification

- `swift build` and `swift test` pass.
- `bash scripts/build-app.sh` produces a signed `.app` with `agent-ding.wav`
  visible in `Multiharness.app/Contents/Resources/`.

### Manual verification

After `bash scripts/build-app.sh`:

1. **Background ding.** Cmd-Tab to another app, prompt an agent in
   Multiharness, wait for completion. Expect: chime plays.
2. **Cross-workspace ding.** Multiharness frontmost on workspace B, prompt an
   agent in workspace A. Expect: chime plays when A finishes.
3. **Same-workspace silence.** Multiharness frontmost on workspace A, prompt
   an agent in workspace A. Expect: no sound.
4. **Toggle off.** Settings → Defaults → toggle "Play sound..." off. Repeat
   scenario 1. Expect: silence.
5. **Persistence.** Toggle off, quit Multiharness, relaunch. Settings shows
   the toggle still off; no sound on completion.

## File-level changes (preview)

- `Package.swift` — add `resources: [.process("Resources")]` to the
  Multiharness executable target.
- `Sources/Multiharness/Resources/agent-ding.wav` — new asset (binary).
- `Sources/Multiharness/Resources/CREDITS.txt` — license attribution.
- `Sources/Multiharness/Sound/CompletionSoundPlayer.swift` — new.
- `Sources/MultiharnessCore/Sound/CompletionSoundDecision.swift` — new pure
  decision function.
- `Sources/MultiharnessCore/Stores/AppStore.swift` — `playCompletionSound`
  property + load/persist.
- `Sources/Multiharness/App.swift` — wire `CompletionSoundPlayer` into
  `AgentRegistryStore` and call from the `agent_end` branch.
- `Sources/Multiharness/Views/Sheets.swift` — add "Notifications" subsection
  to `DefaultsTab`.
- `Tests/MultiharnessCoreTests/CompletionSoundDecisionTests.swift` — new.

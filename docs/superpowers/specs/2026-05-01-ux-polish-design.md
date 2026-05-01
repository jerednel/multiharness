# UX polish: hover states & transitions

**Date:** 2026-05-01
**Branch:** `jerednel/ux-polish`

## Goal

Add interactivity feedback and motion to the Mac and iOS apps so they feel like contemporary peers of Linear / Raycast / Conductor rather than a barebones SwiftUI prototype. Specifically:

- **Hover states** on every clickable affordance (Mac).
- **Press states** on every clickable affordance (iOS — and Mac, where mouse-down feedback also benefits).
- **Simple transitions** when sheets and popovers open, when tabs change, and when disclosures expand/collapse.

The chosen feel is **Conductor-style modern**, ~200ms timings — visible polish without flash.

## Non-goals

- Replacing the system `.sheet` presentation animation. The toolkit layers on top of it; it does not fight the OS.
- Drag-to-dismiss gestures, custom presentation transitions, or overlays masquerading as sheets.
- Haptics on iOS press.
- Animating new message arrival in chat. Streaming agents emit dozens of messages/second; entry animations would be chaotic. Animations apply only to **user-initiated** state changes.
- Color-scheme-aware tuning beyond what `.primary.opacity(...)` already adapts.
- Refactoring or restyling beyond the polish itself. This is presentational.

## Toolkit

Four new files under `Sources/MultiharnessClient/UI/` (a new namespace within the shared package — currently MultiharnessClient holds only models and wire types). Lives in shared so iOS picks it up; macOS-only behavior is gated with `#if os(macOS)`.

### `Motion.swift`

```swift
import SwiftUI

enum Motion {
    static let fast: Animation       = .easeInOut(duration: 0.15)  // hover, press
    static let standard: Animation   = .easeOut(duration: 0.20)    // tab/sheet entry
    static let exit: Animation       = .easeIn(duration: 0.15)     // sheet/popover exit
    static let disclosure: Animation = .spring(response: 0.30, dampingFraction: 0.85)

    static let hoverFill: Color       = .primary.opacity(0.06)
    static let hoverFillStrong: Color = .primary.opacity(0.10)  // rows, selectable items

    /// Returns `.linear(duration: 0)` if `reduceMotion` is true, else the original animation.
    static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : animation
    }
}
```

### `MultiharnessButtonStyle.swift`

A single `ButtonStyle` (with a small variant) that handles hover (Mac) and press (both):

- **`.standard`** — text or text+leading-icon buttons. Padded background.
- **`.icon`** — square icon-only buttons (toolbar, composer, sidebar caret). Background fill is a circle/rounded-square.

Behavior:

- **Press:** `scaleEffect(isPressed ? 0.97 : 1.0)` + `opacity(isPressed ? 0.7 : 1.0)`, animated with `Motion.fast`.
- **Hover (macOS only):** `.background(isHovered ? Motion.hoverFill : .clear)` driven by `.onHover { isHovered = $0 }`. Pointer cursor pushed on enter, popped on exit.
- **Reduce Motion:** press scale collapses to opacity-only; hover fill remains (state indicator, not motion).

Exposed as:

```swift
extension ButtonStyle where Self == MultiharnessButtonStyle {
    static var multiharness: MultiharnessButtonStyle { .init(variant: .standard) }
    static var multiharnessIcon: MultiharnessButtonStyle { .init(variant: .icon) }
}
```

### `HoverableRow.swift`

A `ViewModifier` for tappable rows that aren't `Button`s — e.g., a `ForEach` row whose `.onTapGesture` is owned by a parent. Same hover fill + pointer cursor as the button style, but no press scale (those rows usually trigger selection, not action).

```swift
extension View {
    func hoverableRow(strong: Bool = false) -> some View { … }
}
```

### `Transitions.swift`

Three named transitions wired up via `AnyTransition` extensions:

- **`.sheetEntry`** — `scale(0.97).combined(with: .opacity)` with `Motion.standard` insertion / `Motion.exit` removal. Applied to the **content root inside** a `.sheet` or `.popover`. The system still owns sheet slide/fade; the content scales/fades on top.
- **`.tabSwap`** — `.opacity` crossfade with `Motion.fast`. Used on tab content keyed by selected tab.
- **`.disclosureContent`** — `.opacity.combined(with: .move(edge: .top))` with `Motion.disclosure`. Used inside expand/collapse blocks.

## Surfaces touched

### macOS — `Sources/Multiharness/Views/`

| Surface | File | Treatment |
|---|---|---|
| All `.plain` / `.borderless` buttons (sweep) | `Sheets.swift`, `WorkspaceDetailView.swift`, `WorkspaceSidebar.swift`, `RootView.swift`, `ProjectSettingsSheet.swift`, `ReconcileSheet.swift` | `.buttonStyle(.multiharness)` or `.multiharnessIcon` |
| Settings 5-tab header | `Sheets.swift:286–318` | Icon button style on each tab; tab content wrapped in `.transition(.tabSwap)` keyed on selected tab. Add a thin (2pt) accent-colored underline beneath the active tab, animated via `matchedGeometryEffect` so it glides between tabs on selection change. (The current header has no underline; this is new.) |
| Inspector Files/Context tabs | `WorkspaceDetailView.swift:514` | `.transition(.tabSwap)` on tab content |
| Sidebar workspace rows | `WorkspaceSidebar.swift` | `.hoverableRow(strong: true)` on each row's HStack |
| ResponseGroup expand/collapse + tool-call disclosures | `WorkspaceDetailView.swift:277` | Toggle wrapped in `withAnimation(Motion.disclosure)`; chevron rotates 90° in the same animation; expanded content uses `.transition(.disclosureContent)` |
| Sheets — NewProject, NewWorkspace, ProjectSettings, Reconcile, Settings, RenameWorkspace | `Sheets.swift`, `ProjectSettingsSheet.swift`, `ReconcileSheet.swift`, `WorkspaceSidebar.swift:60` | Sheet content root wrapped in `.transition(.sheetEntry)` |
| Model switcher popover | `WorkspaceDetailView.swift:617` | `.transition(.sheetEntry)` on popover content root |

### iOS — `ios/Sources/MultiharnessIOS/Views/`

| Surface | File | Treatment |
|---|---|---|
| Workspace list rows | `WorkspacesView.swift` | `.buttonStyle(.multiharness)` (press scale + opacity) |
| RootView primary buttons | `RootView.swift:232, 263–278` | `.buttonStyle(.multiharness)` |
| Mac switcher / Pairing sheets | `RootView.swift:24, 41` | `.transition(.sheetEntry)` on content root |
| WorkspaceDetailView disclosures | `ios/.../WorkspaceDetailView.swift` | `Motion.disclosure` on expand/collapse |

### Explicitly NOT touched

- New message arrival in chat (instant)
- Token streaming (`text_delta`) — instant
- iOS list system tap highlight — left alone (system already provides; the button style layers on top)
- Toolbar buttons that already use `.borderedProminent` — system handles them well enough

## Platform mechanics

### Sheet transition caveat

SwiftUI's `.sheet()` owns its presentation animation; you can't replace it. `.transition(.sheetEntry)` animates the **content root inside** the sheet as it appears: the sheet slides in via the system, then the content scales 0.97→1.0 and fades. Net effect: cohesive entry without fighting the OS. Same trick applies for `.popover`.

### iPad with trackpad

`.onHover` fires correctly on iPadOS when a pointer is connected. The shared `.multiharness` button style picks this up automatically — no extra branch needed.

### Reduce Motion

`@Environment(\.accessibilityReduceMotion)` is read in the toolkit primitives. When `true`:

- All `Motion.*` animations resolve to `.linear(duration: 0)` (instant).
- Hover fill still applies (it's a state indicator, not motion).
- Press scale collapses to opacity-only.

The `Motion.adaptive(_:reduceMotion:)` helper centralizes this; views don't sprinkle `if reduceMotion`.

## Effort estimate

- **Toolkit:** ~150 LOC across 4 new files in `MultiharnessClient/UI/`.
- **Mac sweep:** ~10 files modified, mostly one-liner button style swaps + a handful of `.transition` modifiers.
- **iOS sweep:** ~3 files modified.
- **Total:** ~17 files touched. No data model changes, no migrations, no wire-protocol changes.

## Testing

Pure presentational changes. No new XCTest coverage.

Manual verification (`bash scripts/build-app.sh && open dist/Multiharness.app` for Mac; `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh` for iOS):

1. **Mac hover sweep** — every button changes background on hover; cursor becomes pointer.
2. **Mac press** — buttons scale-down on mouse-down; spring back on release.
3. **iOS press** — workspace rows and primary buttons scale-down on touch-down.
4. **Sheets** — open NewWorkspace, Settings, ProjectSettings, Reconcile; each fades+scales in.
5. **Settings tabs** — switching tabs crossfades content; underline glides via matchedGeometryEffect.
6. **Inspector tabs** — Files↔Context crossfades.
7. **Disclosures** — expand a tool-call inside a response group; chevron rotates and content slides+fades in.
8. **Reduce Motion** — toggle System Settings → Accessibility → Display → Reduce Motion; verify everything goes instant but hover fill still appears.

## Risks

- **`.onHover` perf with many list rows.** SwiftUI's `.onHover` is cheap, but the workspace sidebar can have 50+ rows. Mitigation: `.hoverableRow()` keeps state local to each row; no parent re-render.
- **Sheet content `.transition` not firing.** SwiftUI sometimes elides the transition if content isn't conditionally rendered. The sheet's content closure is re-built each presentation, which usually suffices; if a specific sheet doesn't animate, wrap its body in an explicit `if true` placeholder gated by `.onAppear` state to give SwiftUI an identity change to drive the transition.
- **Pointer cursor leaking.** `NSCursor.push()` / `.pop()` must be balanced. If a view disappears mid-hover (e.g., sheet dismissed), the pop may not fire. Mitigation: also call `NSCursor.pop()` in an `.onDisappear` inside the button style.

# Markdown Message Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render assistant message text on Mac and iOS with proper markdown formatting (fenced code blocks, GFM tables, inline code, lists, bold/italic) instead of as raw characters.

**Architecture:** Add `swift-markdown-ui` as a Swift Package dependency on the shared `MultiharnessClient` target. Introduce a single shared SwiftUI view, `MarkdownMessageText`, that renders a `String` with a chat-tuned theme. Replace `Text(turn.text)` with `MarkdownMessageText(turn.text)` at the assistant-turn render sites only — user and tool-output rendering stay as plain `Text`.

**Tech Stack:** Swift 5.10, SwiftUI, swift-markdown-ui 2.4+ (CommonMark + GFM tables), macOS 14, iOS 17.

**Spec:** `docs/superpowers/specs/2026-04-29-markdown-message-rendering-design.md`

---

## File Structure

**New files:**
- `Sources/MultiharnessClient/Views/MarkdownMessageText.swift` — public SwiftUI view that takes a `String` and renders it with `swift-markdown-ui` and a chat-friendly theme. ~120 LOC.

**Modified files:**
- `Package.swift` — add `swift-markdown-ui` dependency and link `MarkdownUI` to the `MultiharnessClient` target.
- `Sources/Multiharness/Views/WorkspaceDetailView.swift` — line 257: replace `Text(turn.text)` with `MarkdownMessageText` for the assistant role only.
- `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift` — line 119: same conditional replacement.

Each task below produces a self-contained, committable change.

---

## Task 1: Add swift-markdown-ui dependency to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Open the current `Package.swift`**

The current file (already in repo) declares `dependencies: []`. We need to:
1. Add `swift-markdown-ui` to the package dependencies.
2. Link the `MarkdownUI` product into the `MultiharnessClient` target so both the Mac executable and the iOS app pick it up transitively.

- [ ] **Step 2: Apply the edit**

Use the Edit tool. Replace this block:

```swift
    dependencies: [],
    targets: [
        // Portable code that ships in BOTH the macOS app and the iOS companion:
        // models, ConversationTurn, ControlClient (URLSessionWebSocketTask), Keychain wrapper.
        .target(
            name: "MultiharnessClient",
            dependencies: [],
            path: "Sources/MultiharnessClient"
        ),
```

With:

```swift
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        // Portable code that ships in BOTH the macOS app and the iOS companion:
        // models, ConversationTurn, ControlClient (URLSessionWebSocketTask), Keychain wrapper.
        .target(
            name: "MultiharnessClient",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources/MultiharnessClient"
        ),
```

- [ ] **Step 3: Resolve dependencies and verify the package builds**

Run: `swift package resolve`
Expected: Resolves swift-markdown-ui plus its transitive deps (NetworkImage and swift-cmark-gfm) without error.

Run: `swift build`
Expected: Build succeeds with the new dependency. No source code change yet, so MultiharnessClient compiles unchanged.

- [ ] **Step 4: Run existing tests to confirm no regression**

Run: `swift test`
Expected: All 5 existing tests in `MultiharnessCoreTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Add swift-markdown-ui dependency to MultiharnessClient"
```

---

## Task 2: Create MarkdownMessageText view with chat theme

**Files:**
- Create: `Sources/MultiharnessClient/Views/MarkdownMessageText.swift`

- [ ] **Step 1: Create the new directory and file**

Use the Write tool to create `Sources/MultiharnessClient/Views/MarkdownMessageText.swift` with this exact content:

```swift
import SwiftUI
import MarkdownUI

public struct MarkdownMessageText: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Markdown(text)
            .markdownTheme(.multiharnessChat)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension Theme {
    static let multiharnessChat: Theme = Theme()
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
            FontSize(.em(1.0))
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.95))
            BackgroundColor(.codeInlineBackground)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .link {
            ForegroundColor(.linkColor)
            UnderlineStyle(.single)
        }
        .heading1 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.25))
                }
        }
        .heading2 { configuration in
            configuration.label
                .markdownMargin(top: 8, bottom: 4)
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(.em(1.15))
                }
        }
        .heading3 { configuration in
            configuration.label
                .markdownMargin(top: 6, bottom: 3)
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(.em(1.05))
                }
        }
        .paragraph { configuration in
            configuration.label
                .markdownMargin(top: 0, bottom: 6)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .relativeLineSpacing(.em(0.20))
                    .markdownTextStyle {
                        FontFamilyVariant(.monospaced)
                        FontSize(.em(0.92))
                    }
                    .padding(8)
            }
            .background(Color.codeBlockBackground)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .markdownMargin(top: 4, bottom: 8)
        }
        .blockquote { configuration in
            HStack(spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2)
                configuration.label
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .table { configuration in
            ScrollView(.horizontal, showsIndicators: false) {
                configuration.label
            }
            .markdownMargin(top: 4, bottom: 8)
        }
        .tableCell { configuration in
            configuration.label
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
        }
        .tableBorder { _ in
            // Default border — thin secondary-color line on every edge.
        }
}

private extension Color {
    static let codeInlineBackground = Color.secondary.opacity(0.15)
    static let codeBlockBackground = Color.secondary.opacity(0.10)
    static let linkColor = Color.accentColor
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build`
Expected: Builds cleanly. The view is not yet referenced by any caller, but its target (`MultiharnessClient`) compiles.

- [ ] **Step 3: Commit**

```bash
git add Sources/MultiharnessClient/Views/MarkdownMessageText.swift
git commit -m "Add MarkdownMessageText shared view with chat theme"
```

---

## Task 3: Wire MarkdownMessageText into the Mac app

**Files:**
- Modify: `Sources/Multiharness/Views/WorkspaceDetailView.swift` (line 257)

- [ ] **Step 1: Confirm the existing call site**

The current `messageCard` body (lines 247–264) renders both user and assistant turns with `Text(turn.text)`. Per spec, only assistant turns should get markdown rendering — user turns stay as plain `Text`.

- [ ] **Step 2: Apply the edit**

Use the Edit tool. Replace this block in `Sources/Multiharness/Views/WorkspaceDetailView.swift`:

```swift
            Text(turn.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(messageBackground, in: RoundedRectangle(cornerRadius: 8))
                .textSelection(.enabled)
```

With:

```swift
            Group {
                if turn.role == .assistant {
                    MarkdownMessageText(turn.text)
                } else {
                    Text(turn.text)
                        .textSelection(.enabled)
                }
            }
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(messageBackground, in: RoundedRectangle(cornerRadius: 8))
```

Note: `MarkdownMessageText` has its own internal `.textSelection(.enabled)` so we don't need to re-apply it inside the `if` branch. The `Group` lets us share the surrounding bubble styling for both branches.

- [ ] **Step 3: Verify the import is in scope**

Check the top of `Sources/Multiharness/Views/WorkspaceDetailView.swift`. It should already `import MultiharnessClient`. If not, add `import MultiharnessClient` near the top (after `import SwiftUI`).

Run: `grep -n "^import" Sources/Multiharness/Views/WorkspaceDetailView.swift` (Use Grep tool, not bash grep.)
Expected: `import MultiharnessClient` is present. If missing, add it.

- [ ] **Step 4: Build the Mac executable**

Run: `swift build`
Expected: Builds cleanly.

- [ ] **Step 5: Run existing tests**

Run: `swift test`
Expected: All 5 existing tests still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/Multiharness/Views/WorkspaceDetailView.swift
git commit -m "Render assistant turns with markdown in Mac app"
```

---

## Task 4: Wire MarkdownMessageText into the iOS app

**Files:**
- Modify: `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift` (line 119)

- [ ] **Step 1: Confirm the existing call site**

The current `messageRow` body (lines 112–130) renders both user and assistant turns with `Text(turn.text)` inside a single bubble. Same conditional logic applies — only assistant gets markdown.

- [ ] **Step 2: Apply the edit**

Use the Edit tool. Replace this block in `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`:

```swift
                Text(turn.text)
                    .font(.body)
                    .padding(8)
                    .background(
                        turn.role == .user ? Color.blue.opacity(0.10) : Color.purple.opacity(0.07),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
```

With:

```swift
                Group {
                    if turn.role == .assistant {
                        MarkdownMessageText(turn.text)
                    } else {
                        Text(turn.text)
                            .textSelection(.enabled)
                    }
                }
                .font(.body)
                .padding(8)
                .background(
                    turn.role == .user ? Color.blue.opacity(0.10) : Color.purple.opacity(0.07),
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
```

- [ ] **Step 3: Verify the import is in scope**

Check the top of `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`. It should already `import MultiharnessClient`. If not, add it.

Run with the Grep tool: pattern `^import`, file `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift`.
Expected: `import MultiharnessClient` is present. If missing, add it.

- [ ] **Step 4: Regenerate the Xcode project and build for iOS**

Run: `bash scripts/build-ios.sh`
Expected: xcodegen regenerates `MultiharnessIOS.xcodeproj` (picking up `MarkdownMessageText.swift` from the package), `xcodebuild` succeeds for iPhone Simulator.

If it fails with "Missing package product 'MarkdownUI'" or similar IDE-cache drift, run:
`MULTIHARNESS_RESET_XCODE_CACHES=1 bash scripts/build-ios.sh`
Expected: Clean rebuild succeeds.

- [ ] **Step 5: Commit**

```bash
git add ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift
git commit -m "Render assistant turns with markdown in iOS app"
```

---

## Task 5: Manual visual verification on Mac

**Files:** none (verification only)

- [ ] **Step 1: Build the Mac app bundle**

Run: `bash scripts/build-app.sh`
Expected: Produces `dist/Multiharness.app` and signs it.

- [ ] **Step 2: Launch the app**

Run: `open dist/Multiharness.app`
Expected: App opens normally. The sidecar binary inside the bundle launches.

- [ ] **Step 3: Send a markdown-heavy prompt to the agent**

In the app, open or create a workspace and send the agent a message like:

```
Reply with: a heading "## Test", a fenced ```python code block (def f(): return 1), an inline `code` span, a bullet list with 3 items, a 2x3 GFM table, and **bold** plus *italic* text.
```

- [ ] **Step 4: Confirm correct rendering**

Visually verify the assistant's response shows:
- "Test" rendered as a smaller-bold heading (not as `## Test`).
- The Python snippet rendered in a tinted monospaced block (not as raw triple-backticks).
- The ` `code` ` span rendered in a tinted monospaced inline (not with surrounding backticks).
- Bullet list rendered with bullets (not as raw `- ` characters).
- Table rendered as a grid with header and 3 columns × 2 data rows (not as raw pipes).
- Bold and italic visually distinct.
- Selecting any of the above text still works.

- [ ] **Step 5: Confirm user messages stay plain**

Type a user message that contains triple-backticks and pipes — e.g., `here is | a | pipe and ` ```py ` raw text`. Confirm the user-side bubble shows the literal characters (markdown is intentionally NOT applied to user messages).

- [ ] **Step 6: Confirm tool outputs stay plain**

If the agent calls a tool, expand the tool card and confirm the tool output still renders in monospaced plain text without markdown interpretation.

- [ ] **Step 7: Commit verification log (no code changes)**

No commit — verification only. If a regression is found, fix it in the appropriate prior task and re-verify.

---

## Task 6: Manual visual verification on iOS

**Files:** none (verification only)

- [ ] **Step 1: Build and launch the iOS app in the simulator**

Run: `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`
Expected: Boots a sim, installs, and launches the iOS app.

- [ ] **Step 2: Pair with the Mac**

Pair the iOS app to the running Mac instance per the standard pairing flow (QR or paste).

- [ ] **Step 3: Send the same markdown-heavy prompt**

Send the same prompt as Task 5 Step 3.

- [ ] **Step 4: Confirm correct rendering**

Visually verify all the same items as Task 5 Step 4 (heading, fenced code, inline code, list, table, bold, italic, text selection).

Pay special attention to:
- The horizontal scrollability of wide code blocks and tables — they should scroll inside the bubble, not push the bubble wider than the screen.
- That long single-line code samples don't break the row layout.

- [ ] **Step 5: Confirm user messages stay plain on iOS too**

Same as Task 5 Step 5.

- [ ] **Step 6: No commit**

Verification only.

---

## Self-Review Notes

This plan was self-reviewed against the spec at `docs/superpowers/specs/2026-04-29-markdown-message-rendering-design.md` after writing.

**Spec coverage:**
- Add `swift-markdown-ui` dependency → Task 1.
- Shared `MarkdownMessageText` view in `MultiharnessClient/Views/` → Task 2.
- Chat theme (inline code, fenced blocks with horizontal scroll, tables with horizontal scroll, headings, blockquotes, etc.) → Task 2.
- Mac call-site replacement at `WorkspaceDetailView.swift:257` (assistant only) → Task 3.
- iOS call-site replacement at `WorkspaceDetailView.swift:119` (assistant only) → Task 4.
- Manual Mac and iOS visual verification → Tasks 5 and 6.
- `swift test` regression check → Tasks 1 and 3.
- iOS xcodegen regen → Task 4.

**Notes:**
- Tool-output rendering is preserved as plain `Text` (the `if turn.role == .tool` branch in both apps already uses a separate `toolCard`/`toolRow`, untouched by this plan).
- `Package.resolved` is committed in Task 1 to lock the dependency version.

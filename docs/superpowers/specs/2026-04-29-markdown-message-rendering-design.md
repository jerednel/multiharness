# Markdown rendering for assistant messages

## Goal

Render assistant message text with proper markdown formatting on both the Mac and iOS apps. Today both apps pass the raw assistant text into a bare SwiftUI `Text(...)`, so triple-backtick fenced code blocks, GFM tables, lists, inline code, bold, italic, etc., all surface as raw characters rather than formatted output.

The user-visible bug: agents routinely return code samples and tables, and they look like literal `` ``` `` and pipe characters instead of being rendered as code blocks and grids.

## Non-goals

- No syntax highlighting in fenced code blocks. Code renders as plain monospaced text on a tinted background. We can layer a highlighter on later if it proves missed.
- No markdown rendering of **user** messages or **tool outputs**. User input is what the user typed; tool stdout/JSON often contains characters (especially `|`) that would be misinterpreted as GFM tables.
- No streaming-aware partial-fence handling. While the assistant streams a response, an open ` ``` ` will momentarily render as an unterminated code block until the closing fence arrives — same behavior as every other chat client.
- No theme switching, no per-message style controls.

## Architecture

### Dependency

Add `swift-markdown-ui` (https://github.com/gonzalezreal/swift-markdown-ui) as a Swift Package dependency, pinned to a recent stable major (`from: "2.4.0"`). It's a pure-SwiftUI markdown renderer with native CommonMark + GitHub-Flavored Markdown support, including tables.

`Package.swift`:
- Add the package to the `dependencies` array.
- Expose the `MarkdownUI` product on the `MultiharnessClient` target so both the Mac executable and the iOS app pick it up transitively.

The iOS Xcode project already resolves SwiftPM products via the existing `xcodegen` flow — adding the dependency to the Swift package is sufficient; no manual Xcode wiring required.

### New shared view: `MarkdownMessageText`

Lives at `Sources/MultiharnessClient/Views/MarkdownMessageText.swift` (new `Views/` subdirectory inside the existing `MultiharnessClient` target).

```swift
public struct MarkdownMessageText: View {
    private let text: String
    public init(_ text: String) { self.text = text }
    public var body: some View {
        Markdown(text)
            .markdownTheme(.multiharnessChat)
            .textSelection(.enabled)
    }
}
```

The view is a thin wrapper. It knows nothing about turn types, styling environments, or message metadata — callers pass in a `String` and get a `View`.

### Theme

Defined as a private `Theme` extension in the same file: `Theme.multiharnessChat`. Specifics:

- **Body paragraphs** — system body font, primary text color. Matches today's `Text` rendering.
- **Inline code** (`` `foo` ``) — `.system(.body, design: .monospaced)`, background `Color.secondary.opacity(0.15)`, 4pt horizontal padding, 2pt corner radius.
- **Fenced code blocks** — `.system(.callout, design: .monospaced)`, background `Color.secondary.opacity(0.10)`, 8pt internal padding, 6pt corner radius. **Wrapped in horizontal `ScrollView`** so long lines neither wrap nor clip. Language tag is ignored.
- **Tables** — native cell grid with thin separators; header row uses `.fontWeight(.semibold)`. Wrapped in horizontal `ScrollView` so wide tables scroll within the message bubble.
- **Headings** — h1/h2 slightly larger than body (`.title3` weight); h3+ rendered as bold body. Chat doesn't need full document heading hierarchy.
- **Lists** — default `swift-markdown-ui` rendering for bullets and ordered lists.
- **Blockquotes** — left-side accent bar (2pt-wide `Color.secondary.opacity(0.4)` rectangle) with indented text.
- **Bold / italic / links** — default theme behavior. Links are tappable on iOS and clickable on Mac.

### Call-site changes

Two single-line replacements:

1. **Mac** — `Sources/Multiharness/Views/WorkspaceDetailView.swift:257`
   - Before: `Text(turn.text)`
   - After:  `MarkdownMessageText(turn.text)`
   - Only the assistant turn branch is changed. The user-message and tool-output `Text(...)` calls are untouched.

2. **iOS** — `ios/Sources/MultiharnessIOS/Views/WorkspaceDetailView.swift:119`
   - Same change, same scope.

Both files already import `MultiharnessClient`, so no new imports are needed.

## Risks and edge cases

- **Streaming partial fences.** As deltas arrive, an in-flight ` ``` ` will render as an open code block until the closing fence streams in. Acceptable; consistent with industry norms.
- **Wide tables / wide code lines.** Mitigated by horizontal `ScrollView` wrappers in the theme.
- **Pipe characters in non-table assistant text.** GFM tables require a header line followed by a `|---|` separator line, so prose containing stray `|` won't get misinterpreted.
- **Re-parse cost on every delta.** `swift-markdown-ui` re-parses on each text update. For chat-length strings this is negligible; if it ever becomes a hotspot, the library accepts a `MarkdownContent` value that can be cached.
- **Dependency footprint.** First external dependency on the Swift side. The library is MIT-licensed, ~5K stars, actively maintained. Worth the cost given the alternative (hand-rolling a GFM table renderer) is significantly more work and error-prone.

## Testing & verification

The view is pure presentation; unit testing has limited value. Validation is visual.

1. **Build / typecheck** — `swift build` succeeds; `bash scripts/build-app.sh` produces a working app bundle; `bash scripts/build-ios.sh` succeeds.
2. **Existing tests** — `swift test` keeps the 5 XCTest tests green.
3. **Manual Mac verification** — launch the app, send a prompt that produces a fenced code block, a GFM table, inline code, an ordered list, and bold/italic text. Confirm each renders correctly and text selection still works.
4. **Manual iOS verification** — `MULTIHARNESS_RUN_SIM=1 bash scripts/build-ios.sh`, repeat the same prompts in the simulator.

No new automated tests are added. SwiftUI snapshot testing is not currently set up in this repo, and bootstrapping it for a single rendering view is not justified.

## Out of scope (future work)

- Syntax highlighting in fenced code blocks (Splash or Highlightr integration via the library's `CodeSyntaxHighlighter` hook).
- Markdown rendering of user messages or tool outputs (would need careful guarding against false-positive table detection in CLI output).
- Custom link handling (e.g., `mh://` deep links) — current behavior opens links in the system default handler.

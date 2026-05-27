import SwiftUI
import MarkdownUI

/// Markdown text view safe for streaming. While `isStreaming` is true the
/// underlying `Markdown` view is updated at most once every ~150 ms so
/// MarkdownUI's full CommonMark re-parse doesn't fire on every single
/// `text_delta` token (which would freeze the main thread on long
/// responses). Once streaming ends, the final text is rendered
/// immediately at full fidelity.
///
/// This replaces the old pattern of `Text()` during streaming →
/// `MarkdownMessageText()` after, which caused visible content shifts
/// (e.g. newline-separated lists collapsing into paragraphs) because
/// plain `Text` and CommonMark have different line-break semantics.
public struct StreamingMarkdownText: View {
    private let text: String
    private let isStreaming: Bool

    /// The snapshot of `text` that the Markdown view is actually
    /// rendering. Updated on a throttle while streaming, then set to
    /// the final value when streaming stops.
    @State private var renderedText: String = ""

    /// Monotonic timestamp (seconds) of the last time we pushed a new
    /// snapshot to `renderedText`. Compared against the throttle
    /// interval on every `text` change to decide whether to update now
    /// or skip.
    @State private var lastRenderTime: CFAbsoluteTime = 0

    /// Scheduled work item that fires after the throttle window to
    /// flush any trailing text that arrived after the last render.
    @State private var trailingFlush: DispatchWorkItem?

    /// How often (seconds) to allow a re-render while streaming.
    /// 150 ms ≈ 7 fps — fast enough to feel live, slow enough that
    /// MarkdownUI's parser cost is negligible.
    private static let throttleInterval: CFAbsoluteTime = 0.15

    public init(_ text: String, isStreaming: Bool) {
        self.text = text
        self.isStreaming = isStreaming
    }

    public var body: some View {
        MarkdownMessageText(renderedText)
            .onChange(of: text, initial: true) { _, newText in
                if isStreaming {
                    throttledUpdate(newText)
                } else {
                    // Not streaming — render immediately.
                    trailingFlush?.cancel()
                    trailingFlush = nil
                    renderedText = newText
                }
            }
            .onChange(of: isStreaming) { _, streaming in
                if !streaming {
                    // Streaming just ended — flush the final text now.
                    trailingFlush?.cancel()
                    trailingFlush = nil
                    renderedText = text
                }
            }
    }

    private func throttledUpdate(_ newText: String) {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastRenderTime

        if elapsed >= Self.throttleInterval {
            // Enough time has passed — render now.
            renderedText = newText
            lastRenderTime = now
            trailingFlush?.cancel()
            trailingFlush = nil
        }

        // Schedule (or reschedule) a trailing flush so the final chunk
        // of text that arrives within the throttle window still gets
        // rendered promptly. Without this, the last ~150 ms of deltas
        // would stay invisible until `isStreaming` flips to false.
        trailingFlush?.cancel()
        let item = DispatchWorkItem { [newText] in
            renderedText = newText
            lastRenderTime = CFAbsoluteTimeGetCurrent()
        }
        trailingFlush = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.throttleInterval,
            execute: item
        )
    }
}

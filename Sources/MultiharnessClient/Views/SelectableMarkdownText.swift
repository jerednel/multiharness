import SwiftUI
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

/// Renders markdown as an `NSAttributedString` inside a read-only
/// `NSTextView`. Unlike MarkdownUI's SwiftUI-native renderer (which
/// builds a `VStack` of separate `Text` views per block), NSTextView
/// supports free-form text selection across paragraph, heading, table,
/// and code-block boundaries — exactly the behavior users expect when
/// they click-and-drag or Cmd-A to copy a response.
///
/// The view is non-editable, transparent-background, and self-sizing:
/// it measures the text layout height and sets its own frame, so the
/// parent SwiftUI ScrollView can lay it out like any other view.
public struct SelectableMarkdownText: View {
    private let markdown: String

    public init(_ markdown: String) {
        self.markdown = markdown
    }

    public var body: some View {
        SelectableMarkdownTextRepresentable(markdown: markdown)
            // Fixed height avoids the "scroll-inside-scroll" problem:
            // the text view is sized to its full content height and
            // the parent SwiftUI ScrollView handles all scrolling.
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct SelectableMarkdownTextRepresentable: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> MarkdownTextContainerView {
        let container = MarkdownTextContainerView()
        container.textView.isEditable = false
        container.textView.isSelectable = true
        container.textView.drawsBackground = false
        container.textView.isRichText = true
        container.textView.textContainerInset = .zero
        container.textView.textContainer?.lineFragmentPadding = 0
        container.textView.textContainer?.widthTracksTextView = true
        container.textView.isVerticallyResizable = true
        container.textView.isHorizontallyResizable = false
        container.textView.usesAdaptiveColorMappingForDarkAppearance = true
        // Prevent the text view from becoming first responder on click
        // (which would steal focus from the Composer text field).
        // Selection still works — the user can click-and-drag to
        // select text, but a bare click won't move keyboard focus.
        container.textView.isFieldEditor = false
        return container
    }

    func updateNSView(_ container: MarkdownTextContainerView, context: Context) {
        guard container.lastMarkdown != markdown else { return }
        container.lastMarkdown = markdown

        let attrStr = MarkdownAttributedStringRenderer.render(markdown)
        container.textView.textStorage?.setAttributedString(attrStr)
        container.invalidateIntrinsicContentSize()
    }
}

/// An NSView wrapper that hosts an NSTextView directly (no NSScrollView)
/// and reports intrinsicContentSize based on the text layout height.
/// Embedding an NSScrollView inside a SwiftUI ScrollView causes
/// scroll-inside-scroll conflicts; using a bare NSTextView avoids this.
final class MarkdownTextContainerView: NSView {
    let textView = NSTextView()
    var lastMarkdown: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupTextView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTextView()
    }

    private func setupTextView() {
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: topAnchor),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override var intrinsicContentSize: NSSize {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 20)
        }
        // Ensure layout is computed for the current width.
        tc.containerSize = NSSize(width: bounds.width > 0 ? bounds.width : 300, height: .greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let usedRect = lm.usedRect(for: tc)
        return NSSize(width: NSView.noIntrinsicMetric, height: ceil(usedRect.height))
    }

    override func layout() {
        super.layout()
        // When the container width changes (e.g. window resize), re-layout
        // the text and update the intrinsic height so SwiftUI can adjust.
        textView.textContainer?.containerSize = NSSize(
            width: bounds.width, height: .greatestFiniteMagnitude
        )
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        invalidateIntrinsicContentSize()
    }
}

// MARK: - Attributed-string renderer

/// Converts a markdown string into an `NSAttributedString` suitable for
/// display in an `NSTextView`. Uses Apple's Foundation markdown parser
/// (CommonMark + GFM tables) and applies theme-appropriate styles:
/// - Headings (H1–H3) with scaled bold fonts
/// - Code blocks with monospaced font and background tint
/// - Inline code with monospaced font
/// - Block quotes with indentation
/// - Bold, italic, strikethrough
/// - Links with accent color and underline
/// - Lists with indentation
/// - Tables rendered inline (tab-separated, monospaced)
enum MarkdownAttributedStringRenderer {
    static func render(_ markdown: String) -> NSAttributedString {
        let bodyFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let bodyColor = NSColor.labelColor

        // Use the full markdown parser that preserves block-level intents
        // (headers, code blocks, block quotes, tables, lists).
        guard let fullParsed = try? AttributedString(
            markdown: markdown,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .full,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else {
            // Fallback: render as plain text.
            return NSAttributedString(string: markdown, attributes: [
                .font: bodyFont,
                .foregroundColor: bodyColor,
            ])
        }

        let mutable = NSMutableAttributedString(fullParsed)
        applyThemeStyles(to: mutable, bodyFont: bodyFont, bodyColor: bodyColor)
        return mutable
    }

    private static func applyThemeStyles(
        to mutable: NSMutableAttributedString,
        bodyFont: NSFont,
        bodyColor: NSColor
    ) {
        let fullRange = NSRange(location: 0, length: mutable.length)
        let monoFont = NSFont.monospacedSystemFont(ofSize: bodyFont.pointSize * 0.92, weight: .regular)
        let codeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.1)
        let inlineCodeBackground = NSColor.secondaryLabelColor.withAlphaComponent(0.15)

        // Set baseline font and color on the entire range first.
        mutable.addAttribute(.font, value: bodyFont, range: fullRange)
        mutable.addAttribute(.foregroundColor, value: bodyColor, range: fullRange)

        // Default paragraph style with inter-paragraph spacing.
        let defaultParaStyle = NSMutableParagraphStyle()
        defaultParaStyle.paragraphSpacing = 6
        mutable.addAttribute(.paragraphStyle, value: defaultParaStyle, range: fullRange)

        // Walk through and style based on presentation intents.
        mutable.enumerateAttribute(
            .presentationIntentAttributeName,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let intentAttr = value as? PresentationIntent else { return }

            for component in intentAttr.components {
                switch component.kind {
                case .header(let level):
                    let sizes: [Int: CGFloat] = [1: 1.25, 2: 1.15, 3: 1.05]
                    let scale = sizes[level] ?? 1.0
                    let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
                    let headingFont = NSFont.systemFont(
                        ofSize: bodyFont.pointSize * scale,
                        weight: weight
                    )
                    mutable.addAttribute(.font, value: headingFont, range: range)
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.paragraphSpacingBefore = 8
                    paraStyle.paragraphSpacing = 4
                    mutable.addAttribute(.paragraphStyle, value: paraStyle, range: range)

                case .codeBlock:
                    mutable.addAttribute(.font, value: monoFont, range: range)
                    mutable.addAttribute(.backgroundColor, value: codeBackground, range: range)
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.paragraphSpacingBefore = 4
                    paraStyle.paragraphSpacing = 8
                    paraStyle.firstLineHeadIndent = 8
                    paraStyle.headIndent = 8
                    mutable.addAttribute(.paragraphStyle, value: paraStyle, range: range)

                case .blockQuote:
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.firstLineHeadIndent = 16
                    paraStyle.headIndent = 16
                    paraStyle.paragraphSpacingBefore = 4
                    paraStyle.paragraphSpacing = 8
                    mutable.addAttribute(.paragraphStyle, value: paraStyle, range: range)
                    mutable.addAttribute(
                        .foregroundColor,
                        value: NSColor.secondaryLabelColor,
                        range: range
                    )

                case .orderedList, .unorderedList:
                    let paraStyle = NSMutableParagraphStyle()
                    paraStyle.firstLineHeadIndent = 16
                    paraStyle.headIndent = 16
                    paraStyle.paragraphSpacing = 4
                    mutable.addAttribute(.paragraphStyle, value: paraStyle, range: range)

                case .table:
                    let smallMono = NSFont.monospacedSystemFont(
                        ofSize: bodyFont.pointSize * 0.9, weight: .regular
                    )
                    mutable.addAttribute(.font, value: smallMono, range: range)

                default:
                    break
                }
            }
        }

        // Style inline presentation intents (code, bold, italic, strikethrough).
        mutable.enumerateAttribute(
            .inlinePresentationIntent,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let intent = value as? InlinePresentationIntent else { return }
            if intent.contains(.code) {
                let inlineMono = NSFont.monospacedSystemFont(
                    ofSize: bodyFont.pointSize * 0.95, weight: .regular
                )
                mutable.addAttribute(.font, value: inlineMono, range: range)
                mutable.addAttribute(.backgroundColor, value: inlineCodeBackground, range: range)
            }
            if intent.contains(.stronglyEmphasized) {
                let currentFont = mutable.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
                let boldFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .boldFontMask)
                mutable.addAttribute(.font, value: boldFont, range: range)
            }
            if intent.contains(.emphasized) {
                let currentFont = mutable.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? bodyFont
                let italicFont = NSFontManager.shared.convert(currentFont, toHaveTrait: .italicFontMask)
                mutable.addAttribute(.font, value: italicFont, range: range)
            }
            if intent.contains(.strikethrough) {
                mutable.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
        }

        // Style links.
        mutable.enumerateAttribute(
            .link,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard value != nil else { return }
            mutable.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: range)
            mutable.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
    }
}

#endif

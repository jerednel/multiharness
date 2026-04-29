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
}

private extension Color {
    static let codeInlineBackground = Color.secondary.opacity(0.15)
    static let codeBlockBackground = Color.secondary.opacity(0.10)
    static let linkColor = Color.accentColor
}

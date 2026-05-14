import SwiftUI

public struct MultiharnessButtonStyle: ButtonStyle {
    public enum Variant { case standard, icon }

    public var variant: Variant

    public init(variant: Variant = .standard) {
        self.variant = variant
    }

    public func makeBody(configuration: Configuration) -> some View {
        InteractiveBody(configuration: configuration, variant: variant)
    }

    private struct InteractiveBody: View {
        let configuration: Configuration
        let variant: Variant

        @State private var isHovered: Bool = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            let scale: CGFloat = (pressed && !reduceMotion) ? 0.97 : 1.0
            let pressOpacity: Double = pressed ? 0.7 : 1.0

            // NOTE: SwiftUI dims disabled buttons automatically. Don't compound it here.
            return configuration.label
                .padding(padding)
                .background(background)
                .scaleEffect(scale)
                .opacity(pressOpacity)
                .animation(Motion.adaptive(Motion.fast, reduceMotion: reduceMotion), value: pressed)
                .animation(Motion.adaptive(Motion.fast, reduceMotion: reduceMotion), value: isHovered)
                #if os(macOS)
                .onHover { hovering in
                    isHovered = hovering
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .onDisappear {
                    if isHovered {
                        NSCursor.pop()
                        isHovered = false
                    }
                }
                #endif
        }

        private var padding: EdgeInsets {
            switch variant {
            case .standard: return EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8)
            case .icon:     return EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            }
        }

        @ViewBuilder
        private var background: some View {
            let cornerRadius: CGFloat = (variant == .icon) ? 6 : 5
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(isHovered ? Motion.hoverFill : Color.clear)
        }
    }
}

public extension ButtonStyle where Self == MultiharnessButtonStyle {
    static var multiharness: MultiharnessButtonStyle { .init(variant: .standard) }
    static var multiharnessIcon: MultiharnessButtonStyle { .init(variant: .icon) }
}

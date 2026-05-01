import SwiftUI

public struct HoverableRow: ViewModifier {
    public var strong: Bool

    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(strong: Bool = false) {
        self.strong = strong
    }

    public func body(content: Content) -> some View {
        content
            .background(isHovered ? (strong ? Motion.hoverFillStrong : Motion.hoverFill) : Color.clear)
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
}

public extension View {
    func hoverableRow(strong: Bool = false) -> some View {
        modifier(HoverableRow(strong: strong))
    }
}

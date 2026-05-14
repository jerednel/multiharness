import SwiftUI

/// Paints a subtle hover fill behind a tappable row and switches the cursor
/// to a pointing hand on macOS. Pair with `.contentShape(Rectangle())` so the
/// gesture region matches the visual region.
///
/// Pass `selected: true` to suppress the hover fill — useful inside a
/// `List(selection:)` where the system already paints a selection background
/// and a stacked hover fill would over-tint the row.
///
/// NOTE: The hover fill renders **behind** content. If the row has its own
/// opaque `.background(...)` it will mask the hover fill; put the hover
/// modifier on an outer wrapper in that case.
public struct HoverableRow: ViewModifier {
    public var strong: Bool
    public var selected: Bool

    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(strong: Bool = false, selected: Bool = false) {
        self.strong = strong
        self.selected = selected
    }

    private var fill: Color {
        guard isHovered, !selected else { return .clear }
        return strong ? Motion.hoverFillStrong : Motion.hoverFill
    }

    public func body(content: Content) -> some View {
        content
            .background(fill)
            .animation(Motion.adaptive(Motion.fast, reduceMotion: reduceMotion), value: isHovered)
            .animation(Motion.adaptive(Motion.fast, reduceMotion: reduceMotion), value: selected)
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
    /// Paints a hover fill + cursor on macOS. Pass `selected: true` inside a
    /// `List(selection:)` row to suppress the fill when already selected.
    func hoverableRow(strong: Bool = false, selected: Bool = false) -> some View {
        modifier(HoverableRow(strong: strong, selected: selected))
    }
}

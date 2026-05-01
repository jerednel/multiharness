import SwiftUI

public extension AnyTransition {
    static var sheetEntry: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.standard),
            removal:   .opacity.animation(Motion.exit)
        )
    }

    static var tabSwap: AnyTransition {
        .opacity.animation(Motion.fast)
    }

    static var disclosureContent: AnyTransition {
        .opacity.combined(with: .move(edge: .top)).animation(Motion.disclosure)
    }
}

/// Wraps content in a one-frame delayed appear so a `.transition(.sheetEntry)` can fire.
/// SwiftUI's `.sheet` content is rendered immediately; without this, the transition is elided.
public struct SheetEntryModifier: ViewModifier {
    @State private var didAppear: Bool = false

    public init() {}

    public func body(content: Content) -> some View {
        Group {
            if didAppear {
                content.transition(.sheetEntry)
            }
        }
        .onAppear {
            withAnimation(Motion.standard) { didAppear = true }
        }
    }
}

public extension View {
    /// Apply on the root content of a `.sheet` or `.popover` to scale+fade in.
    func sheetEntry() -> some View {
        modifier(SheetEntryModifier())
    }
}

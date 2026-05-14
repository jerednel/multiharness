import SwiftUI

public extension AnyTransition {
    static var sheetEntry: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.97).combined(with: .opacity).animation(Motion.standard),
            removal:   .opacity.animation(Motion.exit)
        )
    }

    /// Opacity transition used with `.id(selection)` to swap tab content.
    ///
    /// For a true overlap-crossfade between two known branches, prefer
    /// `.tabCrossfade(selection:reduceMotion:_:)` on a containing view.
    static var tabSwap: AnyTransition {
        .opacity.animation(Motion.fast)
    }

    static var disclosureContent: AnyTransition {
        .opacity.combined(with: .move(edge: .top)).animation(Motion.disclosure)
    }
}

// MARK: - Sheet entry

/// Animates content into a `.sheet` or `.popover` with a scale + opacity entrance
/// on top of the system's own presentation transition.
///
/// Content is rendered from the first frame (so AppKit/UIKit can measure it for
/// sheet sizing), then a one-shot `.onAppear` animates `scale` 0.97→1.0 and
/// `opacity` 0→1. Reduce Motion collapses this to instant.
public struct SheetEntryModifier: ViewModifier {
    @State private var didAppear: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public func body(content: Content) -> some View {
        content
            .scaleEffect(didAppear ? 1.0 : 0.97)
            .opacity(didAppear ? 1.0 : 0.0)
            .onAppear {
                withAnimation(Motion.standard.adaptive(reduceMotion)) {
                    didAppear = true
                }
            }
    }
}

public extension View {
    /// Apply on the root content of a `.sheet` or `.popover` to scale+fade in.
    func sheetEntry() -> some View {
        modifier(SheetEntryModifier())
    }
}

// MARK: - Tab crossfade

/// Renders two views overlaid and crossfades opacity between them as `selection`
/// changes. Unlike `.id(selection).transition(.tabSwap)`, both views remain in
/// the hierarchy during the transition, producing a true overlap-crossfade
/// rather than fade-out-then-in.
///
/// Use for binary or small-N tab pickers where keeping every branch alive is
/// cheap. For high-cost branches, prefer `.id` + `.transition(.tabSwap)`.
public struct TabCrossfade<Selection: Hashable, A: View, B: View>: View {
    public let selection: Selection
    public let first: Selection
    public let firstView: A
    public let secondView: B

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        selection: Selection,
        first: Selection,
        @ViewBuilder firstView: () -> A,
        @ViewBuilder secondView: () -> B
    ) {
        self.selection = selection
        self.first = first
        self.firstView = firstView()
        self.secondView = secondView()
    }

    public var body: some View {
        ZStack {
            firstView.opacity(selection == first ? 1 : 0)
            secondView.opacity(selection == first ? 0 : 1)
        }
        .animation(Motion.fast.adaptive(reduceMotion), value: selection)
    }
}

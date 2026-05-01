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

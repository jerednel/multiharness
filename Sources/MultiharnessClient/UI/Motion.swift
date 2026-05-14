import SwiftUI

public enum Motion {
    public static let fast: Animation       = .easeInOut(duration: 0.15)
    public static let standard: Animation   = .easeOut(duration: 0.20)
    public static let exit: Animation       = .easeIn(duration: 0.15)
    public static let disclosure: Animation = .spring(response: 0.30, dampingFraction: 0.85)

    public static let hoverFill: Color       = .primary.opacity(0.06)
    public static let hoverFillStrong: Color = .primary.opacity(0.10)

    /// Returns `.linear(duration: 0)` (instant) when reduceMotion is true; otherwise the original animation.
    public static func adaptive(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : animation
    }
}

public extension Animation {
    /// Returns this animation, or `.linear(duration: 0)` if `reduceMotion` is true.
    ///
    /// Use at `withAnimation` call sites so user-driven animations honor
    /// the system Reduce Motion accessibility preference:
    ///
    ///     @Environment(\.accessibilityReduceMotion) private var reduceMotion
    ///     …
    ///     withAnimation(Motion.disclosure.adaptive(reduceMotion)) { … }
    func adaptive(_ reduceMotion: Bool) -> Animation {
        reduceMotion ? .linear(duration: 0) : self
    }
}

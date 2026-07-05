import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

private var ceciliasNotesPrefersReducedMotion: Bool {
#if canImport(UIKit)
    UIAccessibility.isReduceMotionEnabled
#elseif canImport(AppKit)
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
#else
    false
#endif
}

public enum CeciliasNotesSpring {
    public static let snappy  = Animation.spring(response: 0.28, dampingFraction: 0.82)
    public static let smooth  = Animation.spring(response: 0.40, dampingFraction: 0.85)
    public static let bouncy  = Animation.spring(response: 0.35, dampingFraction: 0.70)
    public static let precise = Animation.spring(response: 0.22, dampingFraction: 0.90)

    /// Quick, near-critically-damped spring for ambient chrome (toolbar
    /// auto-hide, banner reveal). Keep this short — chrome should fade,
    /// not flop. ~220ms response, no overshoot.
    public static let fade    = Animation.spring(response: 0.22, dampingFraction: 0.95)
}

// MARK: - Reduce-motion aware animation

public extension Animation {
    /// Returns the spring animation when reduce motion is off, crossfade otherwise.
    static func ceciliasNotesSpring(_ spring: Animation) -> Animation {
        ceciliasNotesPrefersReducedMotion ? .easeInOut(duration: 0.2) : spring
    }
}

public extension View {
    func ceciliasNotesAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        let resolved = ceciliasNotesPrefersReducedMotion
            ? Animation.easeInOut(duration: 0.2)
            : animation
        return self.animation(resolved, value: value)
    }
}

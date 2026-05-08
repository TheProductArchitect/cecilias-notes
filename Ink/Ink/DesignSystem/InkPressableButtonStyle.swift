import SwiftUI

// MARK: - InkPressableButtonStyle

/// Default press feedback for every tappable surface in Ink.
///
/// On touch-down: scales to 0.96 and dims to 95% opacity.
/// On release:    snaps back via a short interactive spring.
///
/// Apple HIG asks for ≥44×44 hit targets. Buttons that visually need a smaller
/// frame (e.g. a 36pt toolbar icon) should declare the visual frame and rely
/// on the call-site expansion (`.contentShape(Rectangle()).frame(minWidth: 44, minHeight: 44)`).
/// This style does NOT enforce a hit target on its own — it stays
/// label-shape-agnostic so it composes with any visual sizing.
public struct InkPressableButtonStyle: ButtonStyle {

    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.95 : 1.0)
            .animation(
                .interactiveSpring(response: 0.15, dampingFraction: 0.7),
                value: configuration.isPressed
            )
    }
}

public extension ButtonStyle where Self == InkPressableButtonStyle {
    /// `Button(...).buttonStyle(.inkPressable)` — the standard press feedback
    /// for every interactive surface in Ink.
    static var inkPressable: InkPressableButtonStyle { InkPressableButtonStyle() }
}

// MARK: - Hit target expansion

public extension View {
    /// Expand the tap area of a small visual control (e.g. a 36pt toolbar icon)
    /// to Apple HIG's 44×44 minimum. The visual frame stays unchanged — only
    /// the responder shape grows.
    ///
    /// Usage:
    ///     Button { ... } label: { Image(...).frame(width: 36, height: 36) }
    ///         .buttonStyle(.inkPressable)
    ///         .inkTapTarget()                  // ← gives a 44×44 hit area
    func inkTapTarget(minSize: CGFloat = 44) -> some View {
        self
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
}

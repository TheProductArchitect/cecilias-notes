import SwiftUI

/// Oversized lowercase letter rendered as a near-invisible watermark.
/// Sits behind real content via a `ZStack` and bleeds off the surface
/// it lives on (typically the bottom-right or right edge) so the eye
/// reads it as texture rather than a glyph.
///
/// Used by the splash screen, home masthead, notebook cards, and the
/// notebook header. The `onDarkBackground` flag picks the right
/// 5%-opacity colour for the surface — pass it explicitly rather than
/// relying on the system theme, because the cover-tone surface is not
/// theme-adaptive.
struct GhostLetter: View {
    let character: Character
    let size: CGFloat
    let onDarkBackground: Bool

    var body: some View {
        Text(String(character).lowercased())
            .font(.system(size: size, weight: .heavy))
            .foregroundStyle(
                onDarkBackground
                    ? Color.white.opacity(0.05)
                    : Color.black.opacity(0.05)
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

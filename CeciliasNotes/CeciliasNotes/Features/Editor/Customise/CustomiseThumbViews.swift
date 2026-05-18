import SwiftUI
import UIKit

// MARK: - CoverThumbView

/// Live thumbnail of a `NotebookCover` — paints colour + texture using
/// the same `CoverTextureCanvas` the library cards already use, so the
/// thumbnail matches what the user will see on the card.
struct CoverThumbView: View {
    let cover: NotebookCover
    let size: CGSize
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Color(UIColor(hex: cover.colorHex))
            CoverTextureCanvas(texture: cover.texture)
                .opacity(0.85)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - TemplateThumbView

/// Thumbnail wrapper around `TemplatePatternView` — single source of
/// truth for template rendering, configured in `isThumbnail` mode so
/// the spacing compresses and the line colour reads against the
/// fixed paper-white background. The full-page editor canvas uses
/// the same view in non-thumbnail mode (mounted via UIHostingController
/// inside `PageRenderer`).
///
/// The paper background is hardcoded `#FAFAF8` so thumbs stay
/// recognisable in both light and dark mode. The full page tracks
/// system theme via `PageRenderer.draw(_:)`.
struct TemplateThumbView: View {
    let template: PageTemplate
    let size: CGSize

    private static let paperColour = Color(red: 0.98, green: 0.98, blue: 0.97)

    var body: some View {
        ZStack {
            Self.paperColour
            TemplatePatternView(template: template, isThumbnail: true)
                .padding(2)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

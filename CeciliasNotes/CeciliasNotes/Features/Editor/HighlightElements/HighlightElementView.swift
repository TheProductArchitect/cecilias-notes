import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement(kind: .highlight)` as a coloured
/// translucent rectangle anchored to a region of the PDF page it
/// belongs to. The rect on the HighlightContent is in normalised
/// PDF-page coordinates; the overlay
/// (`HighlightElementsOverlayView`) projects it through the
/// host page's coordinate space before handing the rendered rect
/// to this view.
///
/// Step 5.5: replaces the legacy
/// `PageRenderer.drawTextAnnotationOverlay` Core Graphics pass.
/// Same three style variants supported (highlight / underline /
/// strikethrough); the renderer maps `HighlightStyle` to the
/// appropriate paint.
///
/// Unlike image / PDF / audio elements, highlights are
/// **not resizable or rotatable** — their geometry is tied to PDF
/// text positions; resizing would orphan them from the underlying
/// glyphs. Selection chrome is minimal: a thin border + a trash
/// button. Delete is the only mutation the chrome exposes.
struct HighlightElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: HighlightContent
    /// Pre-projected rect in host-page-canvas coordinates. The
    /// overlay does the PDF-page → host-page projection so this
    /// view doesn't need to know about PDFPageContent / element
    /// bounds. Tracking this as an input makes the rendering
    /// trivial.
    let renderRect: CGRect
    @Binding var isSelected: Bool
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    private static let highlightAlpha: CGFloat = 0.4
    private static let underlineThickness: CGFloat = 1.5

    var body: some View {
        ZStack(alignment: .topLeading) {
            // STRUCTURAL FIX — `.offset`, not `.position`. A
            // `.position`'d paint expands to fill the page-sized
            // overlay; stacked page-sized highlight views then break
            // gesture arbitration (adjacent highlights swallow each
            // other's taps). `.offset` keeps the paint's layout
            // bounds at `renderRect` size. The `.frame(maxWidth/
            // maxHeight: .infinity, .topLeading)` anchors this
            // ZStack to the overlay's top-left so the offset origin
            // is stable — equivalent to the explicit page-sized
            // frame the image / PDF / audio / sticky views carry.
            paint
                .frame(width: renderRect.width, height: renderRect.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if !isSelected { isSelected = true }
                    }
                )
                .offset(x: renderRect.minX, y: renderRect.minY)

            if isSelected {
                selectionChrome
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Paint

    @ViewBuilder
    private var paint: some View {
        switch content.style {
        case .highlight:
            Rectangle()
                .fill(highlightColor.opacity(Self.highlightAlpha))
        case .underline:
            // 1.5pt stroke pinned to the bottom of the rect.
            // Using GeometryReader keeps the line at a fixed
            // thickness regardless of the rect's vertical extent.
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(highlightColor)
                    .frame(height: Self.underlineThickness)
            }
        case .strikethrough:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(highlightColor)
                    .frame(height: Self.underlineThickness)
                Spacer()
            }
        }
    }

    private var highlightColor: Color {
        theme.highlightPalette[content.colorVariant]
            ?? theme.highlightPalette["yellow"]
            ?? Color.yellow
    }

    // MARK: - Selection chrome

    private var selectionChrome: some View {
        ZStack(alignment: .topTrailing) {
            Rectangle()
                .strokeBorder(theme.accent, lineWidth: 1.5)
                .frame(width: renderRect.width, height: renderRect.height)
                .position(x: renderRect.midX, y: renderRect.midY)
                .allowsHitTesting(false)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(theme.accent))
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            }
            .buttonStyle(.plain)
            .position(
                x: renderRect.maxX + 2,
                y: max(11, renderRect.minY - 4)
            )
            .accessibilityLabel("Delete highlight")
        }
    }
}

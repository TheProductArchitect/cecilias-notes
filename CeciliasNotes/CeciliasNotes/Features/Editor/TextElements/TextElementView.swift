import SwiftData
import SwiftUI

/// Renders one V6 `PageElement` of kind `.text` inside its
/// normalised page bounds. Composes `TextEditorRepresentable` for
/// the actual text-editing surface, plus selection chrome (dashed
/// border) and the `TextSizePickerView` popover when selected in
/// cursor mode.
///
/// The first PageElement view in the codebase — pattern is the
/// template Steps 4-7 follow for ImageElementView, AudioElementView,
/// StickyNoteElementView, PDFPageElementView:
///   • Takes `element: PageElement` (positions, rotation) plus a
///     `@Bindable content: <KindContent>` (kind-specific data)
///   • Translates normalised bounds → on-screen rect via `pageSize`
///   • Owns its own `isEditing` / `isSelected` UI state; selection
///     identity is mirrored upward through a binding so the parent
///     overlay can deselect when the user taps elsewhere
///   • Persists via SwiftData's @Bindable propagation — no manual
///     save call needed for content mutations
struct TextElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: TextContent
    let pageSize: CGSize
    /// Set when this element is the currently-selected one in the
    /// overlay. The overlay flips it as selection moves between
    /// elements.
    @Binding var isSelected: Bool
    /// Set when the user has tapped to edit (keyboard up). The
    /// overlay flips it; flipping it here drives the keyboard.
    @Binding var isEditing: Bool

    @Environment(\.theme) private var theme
    /// Page text is ink on paper — its colour must contrast with the
    /// *paper*, which `PageRenderer` paints from the system
    /// light/dark trait, NOT from the app's Theme. Using
    /// `theme.foreground` here made transcription text invisible when
    /// the app's Midnight theme disagreed with the device's light
    /// mode (light ink on light paper). Branch on `colorScheme` so
    /// the ink always tracks the paper.
    @Environment(\.colorScheme) private var colorScheme

    private var pageInkColor: UIColor {
        // Mirrors PageRenderer's paper: #FAFAF8 light / #1C1C1A dark.
        colorScheme == .dark
            ? UIColor(hex: "#EDEDEB")
            : UIColor(hex: "#1C1C1A")
    }

    private var width: CGFloat {
        element.normalizedWidth * pageSize.width
    }
    private var height: CGFloat {
        element.normalizedHeight * pageSize.height
    }
    private var origin: CGPoint {
        CGPoint(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height
        )
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditorRepresentable(
                text: $content.text,
                size: content.size,
                isEditing: $isEditing,
                textColor: pageInkColor
            )
            // Selection chrome — dashed border when selected (and
            // not actively editing; editing implies focus, no need
            // for the extra border).
            .overlay(
                Group {
                    if isSelected && !isEditing {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                theme.accent,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                            .padding(-2)
                    }
                }
            )
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .position(x: origin.x + width / 2, y: origin.y + height / 2)
        .rotationEffect(.radians(element.rotation))
        .onChange(of: content.text) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
        .onChange(of: content.size) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
    }
}

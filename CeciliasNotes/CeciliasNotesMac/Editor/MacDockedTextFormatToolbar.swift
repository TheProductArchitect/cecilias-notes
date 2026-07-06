import SwiftUI

/// Full-width formatting strip — docked below the cover-tone header
/// (Google Docs style). Notes scroll underneath, not behind it.
struct MacDockedTextFormatToolbar: View {
    @ObservedObject var controller: MacRichTextController
    var onNeedsTextFocus: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        MacTextFormatToolbar(controller: controller, onNeedsTextFocus: onNeedsTextFocus)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .frame(height: MacEditorChromeMetrics.formatToolbarHeight)
            .background(theme.surfaceElevated)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
    }
}

#if os(macOS)
extension View {
    /// Hides the default macOS keyboard-focus ring on toolbar controls.
    func macSuppressFocusRing() -> some View {
        focusEffectDisabled()
    }
}
#endif

enum MacEditorChromeMetrics {
    static let headerHeight: CGFloat = 56
    static let collapsedRevealHeight: CGFloat = 28
    static let formatToolbarHeight: CGFloat = 40
}

enum MacDocPageLayout {
    /// Matches iPad `TextElementView.pageMargin`.
    static let horizontalMargin: CGFloat = 32
    static let topMargin: CGFloat = 40
    /// Vertical gap between stacked blocks in doc flow layout.
    static let blockSpacing: CGFloat = 12

    static func normalizedHorizontalMargin(pageWidth: CGFloat) -> Double {
        Double(horizontalMargin / max(1, pageWidth))
    }

    static func normalizedContentWidth(pageWidth: CGFloat) -> Double {
        max(0.5, 1.0 - 2 * normalizedHorizontalMargin(pageWidth: pageWidth))
    }

    static func normalizedTopMargin(pageHeight: CGFloat) -> Double {
        Double(topMargin / max(1, pageHeight))
    }
}

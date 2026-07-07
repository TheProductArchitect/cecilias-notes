import SwiftUI

/// Formatting strip aligned to the document column — sits below the
/// cover-tone header with editorial chrome, not a full-width SaaS bar.
struct MacDockedTextFormatToolbar: View {
    let coverTone: NotebookCoverTone
    var isEditingText: Bool
    @ObservedObject var controller: MacRichTextController
    var onNeedsTextFocus: () -> Void = {}
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: MacDocLayout.horizontalGutter)
            MacTextFormatToolbar(
                controller: controller,
                isEditingText: isEditingText,
                onNeedsTextFocus: onNeedsTextFocus
            )
            .frame(maxWidth: MacDocLayout.contentColumnWidth)
            Spacer(minLength: MacDocLayout.horizontalGutter)
        }
        .frame(maxWidth: .infinity)
        .frame(height: MacEditorChromeMetrics.formatToolbarHeight)
        .background(formatToolbarBackground)
    }

    @ViewBuilder
    private var formatToolbarBackground: some View {
        ZStack(alignment: .bottom) {
            theme.background
            coverTone.background.opacity(coverTone.isLight ? 0.05 : 0.08)
            Rectangle()
                .fill(theme.hairline)
                .frame(height: 0.5)
        }
    }
}

/// Shared layout constants — keep toolbar and page column in register.
enum MacDocLayout {
    static let contentColumnWidth: CGFloat = 720
    static let horizontalGutter: CGFloat = 88
}

enum MacEditorChromeMetrics {
    static let headerHeight: CGFloat = 56
    static let collapsedRevealHeight: CGFloat = 28
    static let formatToolbarHeight: CGFloat = 44
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

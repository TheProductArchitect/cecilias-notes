#if DEBUG
import SwiftUI

// MARK: - IconPreviewView

/// DEBUG-only preview pane showing the app icon at multiple sizes in light + dark.
/// Surfaced from `StyleGuideView`. Iterate on `InkIconRenderer.drawInkForm` and
/// see results live without touching the asset catalogue.
struct IconPreviewView: View {

    private let renderer = InkIconRenderer()
    private let sizes:    [CGFloat] = [16, 32, 64, 128, 512]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.lg) {

            sectionHeader("Light")
            iconRow(theme: .light)

            sectionHeader("Dark")
            iconRow(theme: .dark)
                .padding(Ink.Spacing.md)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.md, style: .continuous))

            sectionHeader("Tinted (system)")
            iconRow(theme: .tinted)

            Text("All renders produced by InkIconRenderer.render(size:theme:cornerRadius:). "
               + "Master SVG: Resources/AppIcon.svg.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(.horizontal, Ink.Spacing.md)
    }

    // MARK: Row

    @ViewBuilder
    private func iconRow(theme: InkIconRenderer.IconTheme) -> some View {
        HStack(alignment: .bottom, spacing: Ink.Spacing.md) {
            ForEach(sizes, id: \.self) { px in
                VStack(spacing: Ink.Spacing.xs) {
                    Image(uiImage: renderer.render(
                        size: CGSize(width: px, height: px),
                        theme: theme,
                        cornerRadius: px * 0.2237
                    ))
                    .interpolation(.high)

                    Text("\(Int(px))")
                        .font(.inkCaption)
                        .foregroundColor(.inkTextTertiary)
                }
            }
            Spacer()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkHeadline)
            .foregroundColor(.inkTextPrimary)
    }
}

#Preview {
    ScrollView { IconPreviewView() }
        .padding()
}
#endif

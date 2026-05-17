#if DEBUG
import SwiftUI

// MARK: - IconPreviewView

/// DEBUG-only preview pane showing brand-icon variants at multiple sizes.
/// Surfaced from `StyleGuideView`. Useful for eyeballing the wordmark
/// composition (letter sizing, kerning, dot baseline) before regenerating
/// the bundled PNGs via `Scripts/GenerateBrandIcons.swift`.
struct IconPreviewView: View {

    private let sizes:    [CGFloat] = [60, 76, 120, 152, 1024]
    private let letters:  [Character] = ["a", "i", "n", "s", "z"]

    var body: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.lg) {
            ForEach(letters, id: \.self) { letter in
                sectionHeader(String(letter).uppercased())
                iconRow(letter: letter)
            }

            Text("Renders via BrandIconRenderer.render(letter:size:). "
               + "Generation script: Scripts/GenerateBrandIcons.swift.")
                .font(.ceciliasNotesCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    @ViewBuilder
    private func iconRow(letter: Character) -> some View {
        HStack(alignment: .bottom, spacing: CeciliasNotes.Spacing.md) {
            ForEach(sizes, id: \.self) { px in
                VStack(spacing: CeciliasNotes.Spacing.xs) {
                    Image(uiImage: BrandIconRenderer.render(letter: letter, size: px))
                        .interpolation(.high)
                        .frame(width: min(px, 120), height: min(px, 120))
                        .clipShape(RoundedRectangle(cornerRadius: min(px, 120) * 0.2237,
                                                    style: .continuous))

                    Text("\(Int(px))")
                        .font(.ceciliasNotesCaption)
                        .foregroundColor(.inkTextTertiary)
                }
            }
            Spacer()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.ceciliasNotesHeadline)
            .foregroundColor(.inkTextPrimary)
    }
}

#Preview {
    ScrollView { IconPreviewView() }
        .padding()
}
#endif

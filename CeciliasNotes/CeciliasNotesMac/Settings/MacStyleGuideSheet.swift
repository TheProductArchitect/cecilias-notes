#if DEBUG
import SwiftUI

/// Compact design reference for the Mac Settings window (DEBUG only).
struct MacStyleGuideSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("cecilia's notes")
                        .font(.system(size: 22, weight: .heavy))
                    Text("editorial chrome — 8pt uppercase eyebrows, 11pt italic rows.")
                        .font(.system(size: 11).italic())
                        .foregroundStyle(theme.foregroundSubtle)

                    HStack(spacing: 8) {
                        swatch(theme.accent, label: "accent")
                        swatch(theme.foreground, label: "foreground")
                        swatch(theme.surface, label: "surface")
                        swatch(theme.background, label: "background")
                    }

                    CeciliasNotesDivider()
                    Text("sample body")
                        .font(.ceciliasNotesBody)
                    CeciliasNotesBadge("DEBUG", style: .accent)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle("style guide")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                }
            }
        }
    }

    private func swatch(_ color: Color, label: String) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(color)
                .frame(width: 44, height: 28)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(theme.hairline, lineWidth: 0.5)
                )
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(theme.recessiveTertiary)
        }
    }
}
#endif

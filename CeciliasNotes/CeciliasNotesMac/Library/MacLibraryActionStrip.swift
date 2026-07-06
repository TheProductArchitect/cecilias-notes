import SwiftUI

/// Top-right library chrome — settings gear and overflow menu, matching iPad `LibraryView.actionStrip`.
struct MacLibraryActionStrip: View {
    @Binding var isShowingRecentExports: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            Spacer()

            Button {
                NotificationCenter.default.post(name: .macOpenSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Menu {
                Button {
                    isShowingRecentExports = true
                } label: {
                    Label("Recent Exports", systemImage: "doc.richtext")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(theme.recessiveTertiary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .accessibilityLabel("More")
        }
        .padding(.horizontal, 24)
        .frame(height: 44)
    }
}

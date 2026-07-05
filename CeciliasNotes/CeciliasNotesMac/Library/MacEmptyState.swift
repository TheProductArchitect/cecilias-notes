import SwiftUI

struct MacEmptyState: View {
    let icon: String
    let title: String
    let message: String
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(theme.foregroundSubtle)
            VStack(spacing: CeciliasNotes.Spacing.xs) {
                Text(title)
                    .font(.system(size: 22))
                    .foregroundStyle(theme.foregroundMuted)
                Text(message)
                    .font(.system(size: 15))
                    .foregroundStyle(theme.foregroundSubtle)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(CeciliasNotes.Spacing.xl)
        .frame(maxWidth: 320)
    }
}

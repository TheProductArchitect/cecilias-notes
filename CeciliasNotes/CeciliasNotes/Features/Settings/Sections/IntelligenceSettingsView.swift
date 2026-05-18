import SwiftUI

/// Settings → Intelligence panel. Surfaces a single master toggle
/// plus an explanatory caption. The whole section is hidden from the
/// rail when the Foundation Models framework isn't available — when
/// it does appear, the only state worth user attention is on / off.
///
/// Editorial style matches the rest of Settings: 8pt tracked
/// uppercase section labels, hairline-only row chrome, no card fills.
struct IntelligenceSettingsView: View {
    @ObservedObject private var intelligence = IntelligenceService.shared
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                masterToggle
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
    }

    private var masterToggle: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("on-device")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Intelligence")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkTextPrimary)
                    Text("summaries, suggested titles, and ask your notes — all run on this device. nothing leaves it.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.foregroundSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $intelligence.intelligenceEnabled)
                    .labelsHidden()
                    .tint(.brandAccent)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}

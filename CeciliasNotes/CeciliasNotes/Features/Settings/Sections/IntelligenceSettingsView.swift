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

    private static let hairlineColour = Color(
        light: Color(hex: "#f5f5f5"),
        dark:  Color(hex: "#1f1f1d")
    )
    private static let labelColour = Color(
        light: Color(hex: "#999999"),
        dark:  Color(hex: "#6a6a67")
    )
    private static let captionColour = Color(
        light: Color(hex: "#aaaaaa"),
        dark:  Color(hex: "#5e5e5c")
    )

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                masterToggle
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(Color(.systemBackground))
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
                        .foregroundStyle(Self.captionColour)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: $intelligence.intelligenceEnabled)
                    .labelsHidden()
                    .tint(.brandAccent)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) {
                Rectangle().fill(Self.hairlineColour).frame(height: 0.5)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(Self.labelColour)
    }
}

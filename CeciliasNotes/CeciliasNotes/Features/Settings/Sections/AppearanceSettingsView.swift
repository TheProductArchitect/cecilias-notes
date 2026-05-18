import SwiftUI

// MARK: - AppearanceSettingsView

/// Phase D redesign: flat white surface, lowercase section labels,
/// theme picker collapsed to two simple rectangles, resume toggle as
/// a hairline-bottom row instead of a card.
struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                themeSection
                resumeSection
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("theme")
            HStack(alignment: .top, spacing: 16) {
                ForEach(Theme.all) { choice in
                    themeOption(choice)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// `choice` is the theme this swatch represents; `theme` (env) is the
    /// user's currently-selected theme — used for chrome that should
    /// reflect the current state (unselected border colour, recessive
    /// label text) rather than the previewed swatch.
    private func themeOption(_ choice: Theme) -> some View {
        let isSelected = viewModel.themeManager.current.id == choice.id
        return Button {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                viewModel.themeManager.setTheme(choice)
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    choice.background
                }
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? theme.accent
                                : theme.hairline,
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )

                Text(choice.displayName.lowercased())
                    .font(.system(size: 9))
                    .foregroundStyle(theme.recessiveQuaternary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(choice.displayName) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("behaviour")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("resume where you left off")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Text("reopen the last notebook at the page you were viewing.")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.recessivePrimary)
                }
                Spacer()
                Toggle("", isOn: $viewModel.resumeEnabled)
                    .labelsHidden()
                    .tint(theme.accent)
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

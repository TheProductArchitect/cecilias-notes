import SwiftUI

// MARK: - AppearanceSettingsView

/// Phase D redesign: flat white surface, lowercase section labels,
/// theme picker collapsed to two simple rectangles, resume toggle as
/// a hairline-bottom row instead of a card.
struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    private static let hairlineColour = Color(
        light: Color(hex: "#f5f5f5"),
        dark:  Color(hex: "#1f1f1d")
    )
    private static let labelColour = Color(
        light: Color(hex: "#999999"),
        dark:  Color(hex: "#6a6a67")
    )

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
        .background(Color(.systemBackground))
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("theme")
            HStack(alignment: .top, spacing: 16) {
                themeOption(.light)
                themeOption(.dark)
                Spacer(minLength: 0)
            }
        }
    }

    private func themeOption(_ theme: CeciliasNotesTheme) -> some View {
        let isSelected = viewModel.themeManager.theme == theme
        return Button {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                viewModel.themeManager.theme = theme
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    swatchFill(for: theme)
                }
                .frame(width: 80, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.brandAccent
                                : Self.hairlineColour,
                            lineWidth: isSelected ? 1.5 : 0.5
                        )
                )

                Text(theme.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(Self.labelColour)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.rawValue) theme")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func swatchFill(for theme: CeciliasNotesTheme) -> some View {
        switch theme {
        case .light: Color.white
        case .dark:  Color(hex: "#0a0a0a")
        }
    }

    private var resumeSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("behaviour")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("resume where you left off")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkTextPrimary)
                    Text("reopen the last notebook at the page you were viewing.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.inkRecessivePrimary)
                }
                Spacer()
                Toggle("", isOn: $viewModel.resumeEnabled)
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

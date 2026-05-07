import SwiftUI

struct PencilSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                doubleTapCard
                pressureCard
                smoothingCard
                togglesCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("Apple Pencil")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Double-tap

    private var doubleTapCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Double-Tap Action")

            Picker("Double-tap", selection: $viewModel.doubleTapAction) {
                ForEach(DoubleTapAction.allCases, id: \.rawValue) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .pickerStyle(.segmented)

            Text("Overrides your system Pencil settings when using Ink.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Pressure

    private var pressureCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Pressure Sensitivity")

            HStack(spacing: Ink.Spacing.sm) {
                ForEach(PressureSetting.allCases, id: \.rawValue) { setting in
                    pressurePill(setting)
                }
            }
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    private func pressurePill(_ setting: PressureSetting) -> some View {
        let selected = viewModel.pressureSetting == setting
        return Button {
            viewModel.pressureSetting = setting
        } label: {
            Text(setting.displayName)
                .font(.inkSubhead)
                .foregroundColor(selected ? .white : .inkTextSecondary)
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.vertical, Ink.Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(selected ? Color.inkAccentPrimary : Color.inkBackgroundSecondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .inkAnimation(InkSpring.snappy, value: selected)
    }

    // MARK: Smoothing

    private var smoothingCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            HStack {
                cardHeader("Stroke Smoothing")
                Spacer()
                Text("\(Int(viewModel.strokeSmoothing))")
                    .font(.inkMono)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }

            Slider(value: $viewModel.strokeSmoothing, in: 0...100, step: 1)
                .tint(.inkAccentPrimary)

            Text("Higher values smooth strokes but reduce responsiveness.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Toggles

    private var togglesCard: some View {
        VStack(spacing: 0) {
            toggleRow(
                "Drawing Haptics",
                systemImage: "hand.tap",
                value: $viewModel.drawingHapticsEnabled
            )

            if viewModel.supportsHoverPreview {
                InkDivider()
                toggleRow(
                    "Pencil Hover Preview",
                    systemImage: "pencil.tip",
                    value: $viewModel.hoverPreviewEnabled
                )
            }
        }
        .inkCard()
    }

    private func toggleRow(_ label: String, systemImage: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(label, systemImage: systemImage)
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
        }
        .toggleStyle(.switch)
        .tint(.inkAccentPrimary)
        .padding(.horizontal, Ink.Spacing.md)
        .padding(.vertical, Ink.Spacing.sm)
    }

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkSubhead)
            .foregroundColor(.inkTextSecondary)
    }
}

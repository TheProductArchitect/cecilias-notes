import SwiftUI

struct PencilSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    /// Bind the segmented picker against `@AppStorage` directly rather
    /// than routing through `viewModel.doubleTapAction`.
    ///
    /// `SettingsViewModel` is a `@MainActor` class with an explicit
    /// `objectWillChange` publisher (synthesised conformance fails under
    /// Swift 5.10's stricter actor isolation). `@AppStorage` properties
    /// on an `ObservableObject` write to UserDefaults but never fire
    /// `objectWillChange`, so views observing the model don't re-render
    /// — toggles and sliders hide this because their gesture animation
    /// snaps regardless of the bound value, but a segmented Picker is
    /// purely value-driven and stays stuck on the previous segment.
    /// Reading via SwiftUI's view-level `@AppStorage` makes the Picker
    /// a proper `DynamicProperty` reader and the segments update.
    @AppStorage("ink.pencil.doubletap") private var doubleTapAction: DoubleTapAction = .switchTool

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                doubleTapCard
                togglesCard
                eraserCard
                // TODO: re-add pressureCard + smoothingCard when a custom stroke
                // renderer ships. PencilKit doesn't expose the hooks needed to
                // honour either setting (audit findings #39, #40).
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

            Picker("Double-tap", selection: $doubleTapAction) {
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

    // MARK: Toggles

    private var togglesCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                toggleRow(
                    "Finger Drawing",
                    systemImage: "hand.draw",
                    value: $viewModel.fingerDrawingEnabled
                )
                Text("Allow drawing with your finger. When off, finger gestures scroll and zoom the canvas.")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextTertiary)
                    .padding(.horizontal, Ink.Spacing.md)
                    .padding(.bottom, Ink.Spacing.sm)
            }

            InkDivider()

            VStack(alignment: .leading, spacing: 2) {
                toggleRow(
                    "Drawing Haptics",
                    systemImage: "hand.tap",
                    value: $viewModel.drawingHapticsEnabled
                )
                Text("Subtle vibration as you draw.")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextTertiary)
                    .padding(.horizontal, Ink.Spacing.md)
                    .padding(.bottom, Ink.Spacing.sm)
            }

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

    // MARK: Eraser

    private var eraserCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            HStack {
                cardHeader("Default Eraser Size")
                Spacer()
                Text("\(Int(viewModel.pixelEraserSize)) pt")
                    .font(.inkMono)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }

            Slider(value: $viewModel.pixelEraserSize, in: 4...80, step: 1)
                .tint(.inkAccentPrimary)

            Text("Starting size when you pick the pixel eraser. Adjust live in the toolbar.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.md)
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

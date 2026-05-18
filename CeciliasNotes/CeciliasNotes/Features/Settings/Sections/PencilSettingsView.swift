import SwiftUI

struct PencilSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.theme) private var theme

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

    /// View-level mirror of the AppStorage key so the Picker
    /// re-renders on selection. Same `DynamicProperty` rationale as
    /// `doubleTapAction` above — `SettingsViewModel`'s
    /// `@AppStorage` properties write through but don't fire
    /// `objectWillChange`.
    @AppStorage("ink.canvas.fingerDrawingMode") private var fingerDrawingMode: FingerDrawingMode = .auto

    var body: some View {
        ScrollView {
            VStack(spacing: CeciliasNotes.Spacing.lg) {
                doubleTapCard
                togglesCard
                if PencilProSupport.isSqueezeSupported {
                    squeezeCard
                }
                // Pixel-eraser size slider removed — PencilKit's
                // default eraser behaviour now governs.
                // TODO: re-add pressureCard + smoothingCard when a custom stroke
                // renderer ships. PencilKit doesn't expose the hooks needed to
                // honour either setting (audit findings #39, #40).
            }
            .padding(CeciliasNotes.Spacing.lg)
        }
        .background(theme.surface.ignoresSafeArea())
        .navigationTitle("Apple Pencil")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Double-tap

    /// List-row picker for the double-tap action. Replaces the
    /// previous `.pickerStyle(.segmented)` form, which couldn't fit
    /// four labels at the Settings sheet's typical width and squashed
    /// surrounding cards.
    private var doubleTapCard: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            cardHeader("Double-Tap Action")

            VStack(spacing: 0) {
                ForEach(DoubleTapAction.allCases, id: \.rawValue) { action in
                    doubleTapRow(action)

                    if action != DoubleTapAction.allCases.last {
                        Divider()
                            .background(theme.recessiveQuaternary.opacity(0.3))
                            .padding(.leading, CeciliasNotes.Spacing.md)
                    }
                }
            }
            .background(theme.surface)

            Text("Overrides your system Pencil settings when using Cecilia's Notes.")
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
        }
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
    }

    private func doubleTapRow(_ action: DoubleTapAction) -> some View {
        let isSelected = doubleTapAction == action
        return Button {
            doubleTapAction = action
        } label: {
            HStack {
                Text(action.displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Toggles

    private var togglesCard: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                fingerDrawingRow
                Text(fingerDrawingMode.detailDescription)
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                    .padding(.horizontal, CeciliasNotes.Spacing.md)
                    .padding(.bottom, CeciliasNotes.Spacing.sm)
            }

            CeciliasNotesDivider()

            VStack(alignment: .leading, spacing: 2) {
                toggleRow(
                    "Drawing Haptics",
                    systemImage: "hand.tap",
                    value: $viewModel.drawingHapticsEnabled
                )
                Text("Subtle vibration as you draw.")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                    .padding(.horizontal, CeciliasNotes.Spacing.md)
                    .padding(.bottom, CeciliasNotes.Spacing.sm)
            }

            if viewModel.supportsHoverPreview {
                CeciliasNotesDivider()
                toggleRow(
                    "Pencil Hover Preview",
                    systemImage: "pencil.tip",
                    value: $viewModel.hoverPreviewEnabled
                )
            }
        }
        .ceciliasNotesCard()
    }

    /// Step 3: replaces the previous Bool toggle with a three-mode
    /// picker. `.auto` follows pencil-detection; `.always` and
    /// `.never` force the policy regardless of detection. The
    /// resolved bool is computed at the canvas mount site against
    /// `InputCapabilityDetector.shared.hasPencil`.
    private var fingerDrawingRow: some View {
        HStack(spacing: CeciliasNotes.Spacing.sm) {
            Image(systemName: "hand.draw")
                .frame(width: 22)
                .foregroundColor(theme.foregroundMuted)
            Text("Finger Drawing")
                .font(.ceciliasNotesBody)
                .foregroundColor(theme.foreground)
            Spacer()
            Picker("Finger Drawing", selection: $fingerDrawingMode) {
                ForEach(FingerDrawingMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .tint(theme.accent)
            .labelsHidden()
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Squeeze (Apple Pencil Pro)

    /// Inline-expanding picker for the squeeze action, gated on
    /// `PencilProSupport.isSqueezeSupported`. Mirrors the
    /// double-tap card's list-row pattern. When "Switch to tool"
    /// is selected, a second card surfaces with the tool list.
    private var squeezeCard: some View {
        VStack(spacing: CeciliasNotes.Spacing.lg) {
            VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
                cardHeader("Squeeze")
                VStack(spacing: 0) {
                    ForEach(SqueezeAction.allCases, id: \.rawValue) { action in
                        squeezeActionRow(action)
                        if action != SqueezeAction.allCases.last {
                            Divider()
                                .background(theme.recessiveQuaternary.opacity(0.3))
                                .padding(.leading, CeciliasNotes.Spacing.md)
                        }
                    }
                }
                .background(theme.surface)

                Text("Squeeze your Apple Pencil Pro to trigger this action.")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
            }
            .padding(CeciliasNotes.Spacing.md)
            .ceciliasNotesCard()

            if viewModel.squeezeAction == .tool {
                squeezeToolCard
            }
        }
    }

    private func squeezeActionRow(_ action: SqueezeAction) -> some View {
        let isSelected = viewModel.squeezeAction == action
        return Button {
            viewModel.squeezeAction = action
        } label: {
            HStack {
                Text(action.displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Tool sub-list shown beneath the squeeze card when "Switch
    /// to tool" is the active action. Same list-row pattern.
    private var squeezeToolCard: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            cardHeader("Tool")
            VStack(spacing: 0) {
                ForEach(SqueezeToolChoice.allCases, id: \.rawValue) { choice in
                    squeezeToolRow(choice)
                    if choice != SqueezeToolChoice.allCases.last {
                        Divider()
                            .background(theme.recessiveQuaternary.opacity(0.3))
                            .padding(.leading, CeciliasNotes.Spacing.md)
                    }
                }
            }
            .background(theme.surface)
        }
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
    }

    private func squeezeToolRow(_ choice: SqueezeToolChoice) -> some View {
        let isSelected = viewModel.squeezeTool == choice
        return Button {
            viewModel.squeezeTool = choice
        } label: {
            HStack {
                Text(choice.displayName)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func toggleRow(_ label: String, systemImage: String, value: Binding<Bool>) -> some View {
        Toggle(isOn: value) {
            Label(label, systemImage: systemImage)
                .font(.ceciliasNotesBody)
                .foregroundColor(theme.foreground)
        }
        .toggleStyle(.switch)
        .tint(theme.accent)
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(.ceciliasNotesSubhead)
            .foregroundColor(theme.foregroundMuted)
    }
}

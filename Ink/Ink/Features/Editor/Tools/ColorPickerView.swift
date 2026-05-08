import SwiftUI
import UIKit

/// Multi-section colour picker shown as a popover anchored to the tool palette's colour dot.
struct ColorPickerView: View {
    @ObservedObject var viewModel: EditorViewModel
    let onClose: () -> Void

    @State private var showCustomColorPicker = false

    private let presetRows: [[String]] = [
        // 5 rows × 8 columns of curated colours.
        ["#000000", "#1D1D1B", "#3A3A3A", "#6B6B68", "#ADADAA", "#D6D6D2", "#F5F5F2", "#FFFFFF"],
        ["#FF3B30", "#FF453A", "#FF9500", "#FFCC00", "#FFD60A", "#34C759", "#30D158", "#00C7BE"],
        ["#5AC8FA", "#30B0C7", "#007AFF", "#0A84FF", "#5856D6", "#5E5CE6", "#AF52DE", "#BF5AF2"],
        ["#FF2D55", "#FF375F", "#A2845E", "#AC8E68", "#8E8E93", "#3F587A", "#2E5734", "#7E1B1B"],
        ["#7E5BAB", "#1E3A5F", "#0D4F0F", "#9C5C00", "#5B3D2F", "#4F1A2C", "#2C2C2E", "#1C1C1A"],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.md) {
            // Recent
            if !viewModel.recentColours.isEmpty {
                section(title: "Recent") {
                    HStack(spacing: 8) {
                        ForEach(Array(viewModel.recentColours.enumerated()), id: \.offset) { _, colour in
                            colourCircle(colour: colour, size: 28)
                        }
                        Spacer()
                    }
                }
            }

            // Presets
            section(title: "Presets") {
                VStack(spacing: 6) {
                    ForEach(Array(presetRows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { hex in
                                colourCircle(colour: UIColor(hex: hex), size: 26)
                            }
                        }
                    }
                }
            }

            // Custom
            Button {
                showCustomColorPicker = true
            } label: {
                HStack {
                    Image(systemName: "eyedropper")
                        .foregroundColor(.inkAccentPrimary)
                    Text("Custom Colour…")
                        .font(.inkBody)
                        .foregroundColor(.inkAccentPrimary)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.inkPressable)

            // Opacity (pen + pencil only)
            if viewModel.selectedTool.hasOpacity {
                Divider()
                opacitySlider
            }
        }
        .padding(Ink.Spacing.md)
        .frame(width: 280)
        .background(Color.inkBackgroundElevated)
        .presentationCompactAdaptation(.popover)
        .sheet(isPresented: $showCustomColorPicker) {
            CustomColorPickerSheet(initial: viewModel.selectedTool.currentColour) { picked in
                viewModel.selectColour(picked)
                showCustomColorPicker = false
                onClose()
            }
        }
    }

    // MARK: Section helper

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
            content()
        }
    }

    // MARK: Single swatch

    private func colourCircle(colour: UIColor, size: CGFloat) -> some View {
        let isSelected = colour.hexString == viewModel.selectedTool.currentColour.hexString

        return Button {
            viewModel.selectColour(colour)
            onClose()
        } label: {
            ZStack {
                Circle()
                    .fill(Color(colour))
                    .frame(width: size, height: size)
                    .overlay(
                        Circle().strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                    )
                if isSelected {
                    Circle()
                        .strokeBorder(Color.inkAccentPrimary, lineWidth: 2)
                        .frame(width: size + 4, height: size + 4)
                }
            }
        }
        .buttonStyle(.inkPressable)
    }

    // MARK: Opacity slider

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opacity")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextTertiary)
                Spacer()
                Text("\(Int(viewModel.selectedTool.currentOpacity * 100))%")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.selectedTool.currentOpacity) },
                    set: { viewModel.setOpacity(CGFloat($0)) }
                ),
                in: 0.10...1.0
            )
            .tint(.inkAccentPrimary)
        }
    }
}

// MARK: - Custom colour picker sheet (UIColorPickerViewController bridge)

private struct CustomColorPickerSheet: UIViewControllerRepresentable {
    let initial: UIColor
    let onPick: (UIColor) -> Void

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let picker = UIColorPickerViewController()
        picker.selectedColor = initial
        picker.supportsAlpha  = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        let onPick: (UIColor) -> Void
        init(onPick: @escaping (UIColor) -> Void) { self.onPick = onPick }

        func colorPickerViewControllerDidFinish(_ vc: UIColorPickerViewController) {
            onPick(vc.selectedColor)
        }
        func colorPickerViewControllerDidSelectColor(_ vc: UIColorPickerViewController) {
            // Live preview not propagated — only commit on dismiss.
        }
    }
}

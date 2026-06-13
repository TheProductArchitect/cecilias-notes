import SwiftUI
import UIKit

/// Multi-section colour picker shown as a popover anchored to the tool palette's colour dot.
struct ColorPickerView: View {
    @ObservedObject var viewModel: EditorViewModel
    let onClose: () -> Void
    @Environment(\.theme) private var theme

    @State private var showCustomColorPicker = false

    /// One row of essentials. The full 40-colour grid was cramped
    /// inside the popover and most users only ever touched a
    /// handful of swatches; everything else is one tap away via
    /// "Custom Colour…". Recent selections sit above the row when
    /// the user has picked colours this session.
    private let presets: [String] = [
        "#000000", // black
        "#FFFFFF", // white
        "#FF3B30", // red
        "#FF9500", // orange
        "#FFCC00", // yellow
        "#34C759", // green
        "#007AFF", // blue
        "#AF52DE", // purple
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
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

            // Presets — one row of essentials.
            section(title: "Presets") {
                HStack(spacing: 6) {
                    ForEach(presets, id: \.self) { hex in
                        colourCircle(colour: UIColor(hex: hex), size: 28)
                    }
                }
            }

            // Custom
            Button {
                showCustomColorPicker = true
            } label: {
                HStack {
                    Image(systemName: "eyedropper")
                        .foregroundColor(theme.accent)
                    Text("Custom Colour…")
                        .font(.ceciliasNotesBody)
                        .foregroundColor(theme.accent)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.ceciliasNotesPressable)

            // Opacity (pen + pencil only)
            if viewModel.selectedTool.hasOpacity {
                Divider()
                opacitySlider
            }
        }
        .padding(CeciliasNotes.Spacing.md)
        .frame(width: 300)
        .background(theme.surfaceElevated)
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
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
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
                        Circle().strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                    )
                if isSelected {
                    Circle()
                        .strokeBorder(theme.accent, lineWidth: 2)
                        .frame(width: size + 4, height: size + 4)
                }
            }
        }
        .buttonStyle(.ceciliasNotesPressable)
    }

    // MARK: Opacity slider

    private var opacitySlider: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Opacity")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                Spacer()
                Text("\(Int(viewModel.selectedTool.currentOpacity * 100))%")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundMuted)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.selectedTool.currentOpacity) },
                    set: { viewModel.setOpacity(CGFloat($0)) }
                ),
                in: 0.10...1.0
            )
            .tint(theme.accent)
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

import SwiftUI
import UIKit

/// Floating, draggable, vertical pill containing tools, current colour, and width controls.
/// Position is persisted to UserDefaults via the ViewModel.
struct ToolPaletteView: View {
    @ObservedObject var viewModel: EditorViewModel

    /// Bounds of the parent — used to clamp the palette inside the editor area.
    let parentSize: CGSize

    @State private var dragOffset: CGSize = .zero
    @State private var showSizePopover = false
    @State private var hasInitialisedPosition = false

    @Namespace private var toolNamespace

    private let paletteWidth:  CGFloat = 48
    private let buttonSize:    CGFloat = 36
    private let edgePadding:   CGFloat = 12

    var body: some View {
        VStack(spacing: Ink.Spacing.xs) {
            toolButton(.pen)
            toolButton(.highlighter)
            toolButton(.pencil)
            toolButton(.eraser)
            toolButton(.lasso)
            toolButton(.ruler)
            toolButton(.text)

            divider

            colourDot

            divider

            sizeControls
        }
        .padding(.vertical, Ink.Spacing.sm)
        .frame(width: paletteWidth)
        .background(paletteBackground)
        .position(currentPosition)
        .gesture(dragGesture)
        .onAppear {
            if !hasInitialisedPosition { initialisePosition() }
        }
        .onChange(of: parentSize) { _, _ in
            // Re-clamp if the editor resizes (e.g. iPad split view, rotation).
            viewModel.toolPalettePosition = clamped(viewModel.toolPalettePosition)
        }
        .popover(isPresented: $viewModel.isShowingColorPicker) {
            ColorPickerView(viewModel: viewModel) {
                viewModel.isShowingColorPicker = false
            }
        }
        .popover(isPresented: $showSizePopover) {
            sizePopover
                .presentationCompactAdaptation(.popover)
        }
    }

    // MARK: Background

    private var paletteBackground: some View {
        RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous)
            .fill(Color.inkBackgroundElevated)
            .overlay(
                RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous)
                    .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
            )
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.inkBorderSubtle)
            .frame(width: paletteWidth - 16, height: 0.5)
    }

    // MARK: Tool button

    private func toolButton(_ identity: InkTool.Identity) -> some View {
        let isActive = viewModel.selectedTool.identity == identity
        return Button {
            handleToolTap(identity)
        } label: {
            ZStack {
                if isActive {
                    // matchedGeometry indicator slides between tools
                    Circle()
                        .fill(Color.inkAccentPrimary.opacity(0.18))
                        .frame(width: 32, height: 32)
                        .matchedGeometryEffect(id: "activeToolIndicator", in: toolNamespace)
                }
                Image(systemName: iconName(for: identity))
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isActive ? .inkAccentPrimary : .inkTextSecondary)
            }
            .frame(width: buttonSize, height: buttonSize)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(A11y.toolLabel(name: toolName(identity), isActive: isActive))
        .accessibilityHint(A11y.toolHint)
        .contextMenu {
            // Eraser: long-press → cycle .pixel / .object
            if identity == .eraser, case .eraser(let mode) = viewModel.selectedTool {
                Button("Pixel Eraser \(mode == .pixel ? "✓" : "")") {
                    viewModel.selectedTool = .eraser(mode: .pixel)
                }
                Button("Object Eraser \(mode == .object ? "✓" : "")") {
                    viewModel.selectedTool = .eraser(mode: .object)
                }
            }
        }
    }

    private func handleToolTap(_ identity: InkTool.Identity) {
        // Tapping the active eraser cycles its mode
        if identity == .eraser, case .eraser(let mode) = viewModel.selectedTool {
            viewModel.selectedTool = .eraser(mode: mode == .pixel ? .object : .pixel)
            HapticManager.shared.toolSwitched()
            return
        }
        // Tapping the active tool is a no-op
        if viewModel.selectedTool.identity == identity { return }
        // Otherwise switch to the default of that identity
        let theme: InkTheme = (UITraitCollection.current.userInterfaceStyle == .dark) ? .dark : .light
        let next: InkTool
        switch identity {
        case .pen:          next = InkTool.Defaults.pen(theme: theme)
        case .highlighter:  next = InkTool.Defaults.highlighter
        case .pencil:       next = InkTool.Defaults.pencil(theme: theme)
        case .eraser:       next = InkTool.Defaults.eraser
        case .lasso:        next = InkTool.Defaults.lasso
        case .ruler:        next = InkTool.Defaults.ruler
        case .text:         next = InkTool.Defaults.text
        }
        // 0.2s spring with the matched-geometry indicator
        withAnimation(.inkSpring(InkSpring.precise)) {
            viewModel.selectTool(next)
        }
        HapticManager.shared.toolSwitched()
    }

    private func iconName(for identity: InkTool.Identity) -> String {
        switch identity {
        case .pen:          return "pencil.tip"
        case .highlighter:  return "highlighter"
        case .pencil:       return "pencil"
        case .eraser:       return "eraser"
        case .lasso:        return "lasso"
        case .ruler:        return "ruler"
        case .text:         return "text.cursor"
        }
    }

    private func toolName(_ identity: InkTool.Identity) -> String {
        switch identity {
        case .pen:          return "Pen"
        case .highlighter:  return "Highlighter"
        case .pencil:       return "Pencil"
        case .eraser:       return "Eraser"
        case .lasso:        return "Lasso"
        case .ruler:        return "Ruler"
        case .text:         return "Text"
        }
    }

    // MARK: Colour dot

    private var colourDot: some View {
        Button {
            guard viewModel.selectedTool.hasColour else { return }
            viewModel.isShowingColorPicker.toggle()
        } label: {
            Circle()
                .fill(Color(viewModel.selectedTool.currentColour))
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .strokeBorder(Color.inkBorderDefault, lineWidth: 0.5)
                )
                .opacity(viewModel.selectedTool.hasColour ? 1 : 0.3)
        }
        .buttonStyle(.plain)
        .frame(width: buttonSize, height: buttonSize)
    }

    // MARK: Size controls

    private var sizeControls: some View {
        VStack(spacing: 2) {
            Button {
                viewModel.incrementWidth()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: buttonSize, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.selectedTool.hasWidth)

            Button {
                showSizePopover = true
            } label: {
                Text(formatWidth(viewModel.selectedTool.currentWidth))
                    .font(.inkCaption)
                    .foregroundColor(.inkTextPrimary)
                    .monospacedDigit()
                    .frame(width: buttonSize, height: 20)
            }
            .buttonStyle(.plain)

            Button {
                viewModel.decrementWidth()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: buttonSize, height: 24)
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.selectedTool.hasWidth)
        }
    }

    private func formatWidth(_ width: CGFloat) -> String {
        if width == 0 { return "—" }
        if width.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(width))"
        }
        return String(format: "%.1f", width)
    }

    private var sizePopover: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            Text("Width")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.selectedTool.currentWidth) },
                        set: { viewModel.setWidth(CGFloat($0)) }
                    ),
                    in: 0.5...20.0,
                    step: 0.5
                )
                .tint(.inkAccentPrimary)
                Text(formatWidth(viewModel.selectedTool.currentWidth))
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(Ink.Spacing.md)
        .frame(width: 240)
    }

    // MARK: Drag handling

    private var currentPosition: CGPoint {
        let base = viewModel.toolPalettePosition
        return CGPoint(x: base.x + dragOffset.width,
                       y: base.y + dragOffset.height)
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let raw = CGPoint(
                    x: viewModel.toolPalettePosition.x + value.translation.width,
                    y: viewModel.toolPalettePosition.y + value.translation.height
                )
                viewModel.toolPalettePosition = clamped(raw)
                dragOffset = .zero
                viewModel.persistToolPalettePosition()
            }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let halfW: CGFloat = paletteWidth / 2 + edgePadding
        // Total height of the palette varies with size text, but we use a conservative estimate.
        let halfH: CGFloat = 200
        let x = max(halfW, min(parentSize.width  - halfW, point.x))
        let y = max(halfH + edgePadding,
                    min(parentSize.height - halfH - edgePadding, point.y))
        return CGPoint(x: x, y: y)
    }

    private func initialisePosition() {
        hasInitialisedPosition = true
        // Default: right edge, vertically centred
        if viewModel.toolPalettePosition.x < 0 {
            viewModel.toolPalettePosition = CGPoint(
                x: parentSize.width - paletteWidth / 2 - edgePadding,
                y: parentSize.height / 2
            )
            viewModel.persistToolPalettePosition()
        } else {
            viewModel.toolPalettePosition = clamped(viewModel.toolPalettePosition)
        }
    }
}

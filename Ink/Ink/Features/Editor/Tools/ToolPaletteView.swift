import SwiftUI
import UIKit

/// Floating, draggable, vertical pill containing tools, current colour, and width controls.
/// Position is persisted to UserDefaults via the ViewModel.
struct ToolPaletteView: View {
    @ObservedObject var viewModel: EditorViewModel

    /// Bounds of the parent — used to clamp the palette inside the editor area.
    let parentSize: CGSize

    /// Safe-area insets from the editor's `GeometryReader`. The clamp uses these
    /// to keep the palette out of the home indicator + status-bar regions.
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @State private var dragOffset: CGSize = .zero
    @State private var showSizePopover = false
    @State private var showEraserPopover = false
    @State private var showErasePageConfirm = false
    @State private var hasInitialisedPosition = false

    @AppStorage("ink.eraser.pixelSize") private var pixelEraserSize: Double = 24

    @Namespace private var toolNamespace

    private let paletteWidth:  CGFloat = 48
    private let buttonSize:    CGFloat = 36
    private let edgePadding:   CGFloat = 12

    var body: some View {
        VStack(spacing: Ink.Spacing.xs) {
            dragHandle

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
        .popover(isPresented: $showEraserPopover) {
            eraserPopover
                .presentationCompactAdaptation(.popover)
        }
        .alert("Erase all ink on this page?",
               isPresented: $showErasePageConfirm) {
            Button("Erase", role: .destructive) {
                HapticManager.shared.destructiveConfirmed()
                viewModel.eraseCurrentPage()
                // Revert to the most forgiving default after a one-shot erase.
                viewModel.selectedTool = .eraser(mode: .wholeStroke)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears all strokes on the current page. Media and text blocks are preserved. ⌘Z restores.")
        }
    }

    // MARK: Drag handle (six-dot grip)

    /// The only surface that listens to the drag gesture. Tool buttons below
    /// keep their taps clean — no more accidental palette moves while reaching
    /// for the eraser.
    /// The hit area is padded out beyond the visible dots so quick drags don't
    /// slip off a 40×22 target.
    private var dragHandle: some View {
        VStack(spacing: 3) {
            HStack(spacing: 3) { dot; dot }
            HStack(spacing: 3) { dot; dot }
            HStack(spacing: 3) { dot; dot }
        }
        .frame(width: paletteWidth - 8, height: 22)
        .padding(8)                          // grow the hit area
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .accessibilityElement()
        .accessibilityLabel("Drag handle")
        .accessibilityHint("Drag to reposition the tool palette")
        .accessibilityAddTraits(.isButton)
    }

    private var dot: some View {
        Circle()
            .fill(Color.inkTextTertiary)
            .frame(width: 3, height: 3)
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
        .buttonStyle(.inkPressable)
        .inkTapTarget()
        .accessibilityLabel(A11y.toolLabel(name: toolName(identity), isActive: isActive))
        .accessibilityHint(A11y.toolHint)
        .contextMenu {
            // Eraser: long-press → pick one of the three modes (and one-shot Erase Page).
            if identity == .eraser, case .eraser(let mode) = viewModel.selectedTool {
                Button {
                    viewModel.selectedTool = .eraser(mode: .wholeStroke)
                } label: {
                    Label("Whole Stroke\(mode == .wholeStroke ? "  ✓" : "")", systemImage: "eraser")
                }
                Button {
                    viewModel.selectedTool = .eraser(mode: .pixel)
                } label: {
                    Label("Pixel Eraser\(mode == .pixel ? "  ✓" : "")", systemImage: "eraser.line.dashed")
                }
                Divider()
                Button(role: .destructive) {
                    showErasePageConfirm = true
                } label: {
                    Label("Erase Page…", systemImage: "trash")
                }
            }
        }
    }

    private func handleToolTap(_ identity: InkTool.Identity) {
        // Tapping the active eraser opens the eraser popover (mode picker + size).
        if identity == .eraser, case .eraser = viewModel.selectedTool {
            showEraserPopover = true
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
        .buttonStyle(.inkPressable)
        .frame(width: buttonSize, height: buttonSize)
        .inkTapTarget()
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
            .buttonStyle(.inkPressable)
            .inkTapTarget()
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
            .buttonStyle(.inkPressable)
            .inkTapTarget()

            Button {
                viewModel.decrementWidth()
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.inkTextSecondary)
                    .frame(width: buttonSize, height: 24)
            }
            .buttonStyle(.inkPressable)
            .inkTapTarget()
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

    // MARK: Eraser popover (mode picker + Pixel Eraser size slider)

    private var eraserPopover: some View {
        let activeMode: EraserMode = {
            if case .eraser(let m) = viewModel.selectedTool { return m }
            return .wholeStroke
        }()
        return VStack(alignment: .leading, spacing: Ink.Spacing.md) {
            Text("Eraser")
                .font(.inkSubhead)
                .foregroundColor(.inkTextSecondary)

            VStack(spacing: 0) {
                eraserModeRow(.wholeStroke, isSelected: activeMode == .wholeStroke)
                Divider()
                eraserModeRow(.pixel,       isSelected: activeMode == .pixel)
                Divider()
                erasePageRow
            }
            .background(Color.inkBackgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))

            if activeMode == .pixel {
                VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
                    HStack {
                        Text("Size")
                            .font(.inkCaption)
                            .foregroundColor(.inkTextTertiary)
                        Spacer()
                        Text("\(Int(pixelEraserSize)) pt")
                            .font(.inkCaption)
                            .foregroundColor(.inkTextSecondary)
                            .monospacedDigit()
                    }
                    Slider(value: $pixelEraserSize, in: 4...80, step: 1)
                        .tint(.inkAccentPrimary)
                        .onChange(of: pixelEraserSize) { _, _ in
                            // Re-emit the tool so PKCanvasView picks up the new bitmap width.
                            if case .eraser(.pixel) = viewModel.selectedTool {
                                viewModel.selectedTool = .eraser(mode: .pixel)
                            }
                        }
                }
            }
        }
        .padding(Ink.Spacing.md)
        .frame(width: 260)
    }

    private func eraserModeRow(_ mode: EraserMode, isSelected: Bool) -> some View {
        Button {
            viewModel.selectedTool = .eraser(mode: mode)
        } label: {
            HStack {
                Image(systemName: mode.iconName)
                    .frame(width: 22)
                Text(mode.displayName)
                    .font(.inkBody)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.inkAccentPrimary)
                }
            }
            .foregroundColor(.inkTextPrimary)
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
    }

    private var erasePageRow: some View {
        Button {
            showEraserPopover = false
            // Defer the alert one runloop tick so the popover dismisses cleanly first.
            DispatchQueue.main.async { showErasePageConfirm = true }
        } label: {
            HStack {
                Image(systemName: "trash")
                    .frame(width: 22)
                Text("Erase Page…")
                    .font(.inkBody)
                Spacer()
            }
            .foregroundColor(.inkDestructive)
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
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
        // .global coordinate space — the handle lives inside the moving palette
        // (.position is set from currentPosition), so a .local DragGesture's
        // origin shifts every tick and `value.translation` jitters. Global is
        // stable because it references the screen, not the moving view.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                // No withAnimation here — animating per-tick is the classic
                // cause of laggy/elastic drag feel. Snap to translation directly.
                dragOffset = value.translation
            }
            .onEnded { value in
                let baseX = viewModel.toolPalettePosition.x + value.translation.width
                let baseY = viewModel.toolPalettePosition.y + value.translation.height
                viewModel.toolPalettePosition = clamped(CGPoint(x: baseX, y: baseY))
                dragOffset = .zero
                viewModel.persistToolPalettePosition()
            }
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        let halfW: CGFloat = paletteWidth / 2 + edgePadding
        // Total height of the palette varies with size text, but we use a conservative estimate.
        let halfH: CGFloat = 200
        // Shrink the legal Y range by the safe-area insets so the palette
        // never overlaps the status bar (top) or home indicator (bottom).
        let topLimit    = halfH + edgePadding + safeAreaInsets.top
        let bottomLimit = parentSize.height - halfH - edgePadding - safeAreaInsets.bottom
        let leftLimit   = halfW + safeAreaInsets.leading
        let rightLimit  = parentSize.width - halfW - safeAreaInsets.trailing
        let x = max(leftLimit, min(rightLimit, point.x))
        let y = max(topLimit,  min(max(topLimit, bottomLimit), point.y))
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

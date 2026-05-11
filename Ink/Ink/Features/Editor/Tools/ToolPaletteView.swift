import SwiftUI
import UIKit

/// Floating, edge-snapping pill of tools, current colour, and width controls.
///
/// Position model (Feature 5):
///   • The palette anchors to one of four edges (`ToolbarEdge`).
///   • Edge is persisted **per orientation** in two `@AppStorage` keys.
///   • Layout switches automatically: top/bottom → HStack, left/right → VStack.
///   • Dragging follows the finger; releasing snaps to the nearest edge for
///     the *current* orientation, animated with `InkSpring.snappy`.
struct ToolPaletteView: View {
    @ObservedObject var viewModel: EditorViewModel

    /// Bounds of the parent — used for snap-to-edge calculations.
    let parentSize: CGSize

    /// Safe-area insets from the editor's `GeometryReader`. The palette is
    /// padded inward from the active edge by these so it never overlaps the
    /// home indicator, status bar, or notch.
    var safeAreaInsets: EdgeInsets = EdgeInsets()

    @State private var dragOffset: CGSize = .zero
    @State private var showSizePopover = false
    @State private var showEraserPopover = false
    @State private var showErasePageConfirm = false
    /// Which category, if any, is showing its variant picker popover.
    @State private var openVariantCategory: ToolCategory?

    /// Per-notebook persisted edge — keyed by the notebook UUID per the
    /// redesign spec. Replaces the older per-orientation pair (which
    /// remembered different edges for landscape vs portrait): each
    /// notebook now gets its own remembered position, read on appear
    /// and written on drag-end. Default is `.right` (vertical pill on
    /// the right edge — the closest snap-to-edge analogue of the spec's
    /// "bottom-right" default for users who haven't moved it yet).
    @State private var resolvedEdgeRaw: String = ToolbarEdge.right.rawValue
    private var positionKey: String {
        "toolbar.position.\(viewModel.notebook.id.uuidString)"
    }

    @Namespace private var toolNamespace

    private let paletteThickness: CGFloat = 56        // short axis of the pill
    /// 44pt buttons match Apple HIG's tap-target minimum and pair
    /// with `.contentShape(Rectangle())` inside each Button's label
    /// so Pencil taps register anywhere in the visible button area —
    /// not just on the SF Symbol's glyph.
    private let buttonSize:       CGFloat = 44
    private let edgePadding:      CGFloat = 12
    /// Reserved vertical space at the top edge — equal to the cover-tone
    /// header height (56pt) when the header is on screen, dropping to a
    /// thin 3pt sliver when it has auto-hidden. Reactive so a manual
    /// header reveal animates the palette downward instead of leaving
    /// it tucked under the title.
    private var topToolbarReserved: CGFloat {
        viewModel.headerVisibility.isHeaderVisible ? 56 : 3
    }

    /// Resolved edge — read from `resolvedEdgeRaw` (per-notebook).
    /// Falls back to `.right` if the persisted value can't decode.
    private var edge: ToolbarEdge {
        ToolbarEdge(rawValue: resolvedEdgeRaw) ?? .right
    }

    var body: some View {
        ZStack(alignment: edge.alignment) {
            // Transparent stretchy backdrop pins the palette to the active
            // edge inside its parent. The palette itself is the small pill.
            Color.clear

            paletteBody
                .padding(insetForCurrentEdge())
                .offset(x: dragOffset.width, y: dragOffset.height)
        }
        .ignoresSafeArea(edges: .all)               // we manage insets manually
        .animation(.inkSpring(InkSpring.snappy), value: edge)
        // Re-flow the palette when the header slides in or out so a
        // top-edge palette doesn't end up sitting under the cover-tone
        // header, and snaps back into place when the header hides.
        .animation(.inkSpring(InkSpring.snappy),
                   value: viewModel.headerVisibility.isHeaderVisible)
        .onAppear {
            // Hydrate from per-notebook UserDefaults on first paint.
            if let stored = UserDefaults.standard.string(forKey: positionKey) {
                resolvedEdgeRaw = stored
            }
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

    // MARK: Layout

    /// The pill itself. Lays out as HStack or VStack depending on `edge.axis`.
    @ViewBuilder
    private var paletteBody: some View {
        let content = paletteContents
        switch edge.axis {
        case .vertical:
            VStack(spacing: Ink.Spacing.xs) { content }
                .padding(.vertical, Ink.Spacing.sm)
                .frame(width: paletteThickness)
                .background(paletteBackground)
        case .horizontal:
            HStack(spacing: Ink.Spacing.xs) { content }
                .padding(.horizontal, Ink.Spacing.sm)
                .frame(height: paletteThickness)
                .background(paletteBackground)
        }
    }

    /// Children of the palette, in order. ViewBuilder so HStack/VStack can
    /// pick them up identically. The drag handle goes first — it's the
    /// "leading" element regardless of axis (top of vertical, leading of horizontal).
    /// Order: writing tools, drawing tools, highlighter, modes (eraser/lasso/ruler/text).
    /// A flat layout — grouping/expansion UI is a follow-up.
    @ViewBuilder
    private var paletteContents: some View {
        dragHandle

        // Categories — each button shows its current variant's glyph.
        // Tap to activate (or open variants if already active);
        // long-press always opens the variant popover.
        categoryButton(.pen)
        categoryButton(.pencil)
        categoryButton(.brush)
        categoryButton(.highlighter)

        divider

        // Modes (no variants) — direct buttons.
        toolButton(.eraser)
        toolButton(.lasso)
        toolButton(.ruler)
        toolButton(.text)
        // Image tool — available on every notebook, slots between
        // text and sticky-note per the import spec. Selection and
        // manipulation only kick in when this tool is active; any
        // other tool leaves images inert so handwriting can draw
        // over them undisturbed.
        toolButton(.image)
        // Sticky-note tool surfaces only for PDF-backed notebooks.
        // Non-PDF notebooks have inline text via `.text` and don't
        // need anchored sticky comments.
        if viewModel.notebook.isPDFBacked {
            toolButton(.stickyNote)
        }

        divider
        colourDot
        divider
        sizeControls
        divider
        shapeRecognitionToggle
    }

    // MARK: Shape recognition toggle

    /// Tap to toggle. Active state uses the brand accent.
    private var shapeRecognitionToggle: some View {
        Button {
            viewModel.shapeRecognitionEnabled.toggle()
            HapticManager.shared.toolSwitched()
        } label: {
            // Active state: icon turns brand accent — no fill circle.
            // Phase D removed the filled-pill treatment to match the
            // editorial restraint elsewhere ("select" in the grid
            // toolbar uses colour-only too).
            Image(systemName: "rectangle.dashed.badge.record")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(viewModel.shapeRecognitionEnabled
                                 ? .brandAccent
                                 : .inkRecessiveSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
        .accessibilityLabel(
            viewModel.shapeRecognitionEnabled
                ? "Shape Recognition: on"
                : "Shape Recognition: off"
        )
    }

    /// Inset the pill from the active edge by safe-area + a small visual margin.
    /// The orthogonal axis gets a small breathing margin too so the palette
    /// looks balanced rather than jammed against the corner.
    private func insetForCurrentEdge() -> EdgeInsets {
        let m = edgePadding
        switch edge {
        case .top:
            // Push below the editor toolbar (which lives in this band).
            return EdgeInsets(top: safeAreaInsets.top + topToolbarReserved + m,
                              leading: 0, bottom: 0, trailing: 0)
        case .bottom:
            return EdgeInsets(top: 0, leading: 0, bottom: safeAreaInsets.bottom + m, trailing: 0)
        case .left:
            return EdgeInsets(top: 0, leading: safeAreaInsets.leading + m, bottom: 0, trailing: 0)
        case .right:
            return EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: safeAreaInsets.trailing + m)
        }
    }

    // MARK: Drag handle (six-dot grip)

    /// The only surface that listens to the drag gesture. Tool buttons below
    /// keep their taps clean — no more accidental palette moves while reaching
    /// for the eraser.
    /// The hit area is padded out beyond the visible dots so quick drags don't
    /// slip off a 40×22 target.
    private var dragHandle: some View {
        // 6-dot grid; orientation flips so the "lines" run along the
        // pill's long axis (vertical pill = horizontal rows of dots,
        // horizontal pill = vertical columns of dots). Keeps the visual
        // metaphor of grippy rails regardless of orientation.
        gripDots(axis: edge.axis)
            .frame(width: 24, height: 24)
            .padding(8)                      // grow the hit area
            .contentShape(Rectangle())
            .gesture(dragGesture)
            .accessibilityElement()
            .accessibilityLabel("Drag handle")
            .accessibilityHint("Drag to reposition the tool palette")
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private func gripDots(axis: ToolbarEdge.Axis) -> some View {
        switch axis {
        case .vertical:
            VStack(spacing: 3) {
                HStack(spacing: 3) { dot; dot }
                HStack(spacing: 3) { dot; dot }
                HStack(spacing: 3) { dot; dot }
            }
        case .horizontal:
            HStack(spacing: 3) {
                VStack(spacing: 3) { dot; dot }
                VStack(spacing: 3) { dot; dot }
                VStack(spacing: 3) { dot; dot }
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(Color.inkRecessiveTertiary)
            .frame(width: 2, height: 2)
    }

    // MARK: Background

    private var paletteBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.systemBackground).opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.inkRecessiveQuaternary, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 2)
    }

    @ViewBuilder
    private var divider: some View {
        switch edge.axis {
        case .vertical:
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(width: paletteThickness - 16, height: 0.5)
        case .horizontal:
            Rectangle()
                .fill(Color.inkBorderSubtle)
                .frame(width: 0.5, height: paletteThickness - 16)
        }
    }

    // MARK: Category button (Item 2)

    /// Renders one category as a single button. The icon shown is the
    /// category's *current variant's* glyph (so the Pen button shows a
    /// fountain-pen icon when the user has picked Fountain Pen recently).
    /// A small "more" dot in the corner hints that the category has
    /// other variants — tap an already-active category to open the
    /// variant picker.
    private func categoryButton(_ category: ToolCategory) -> some View {
        let currentVariant = ToolCategoryStore.lastVariant(for: category)
        let isActive       = category.variants.contains(viewModel.selectedTool.identity)

        return Button {
            handleCategoryTap(category)
        } label: {
            // Phase D: active state is icon-colour-only (brand accent),
            // no filled pill. The matched-geometry indicator is gone
            // with the fill — there's nothing to slide between buttons
            // any more.
            ZStack {
                Image(systemName: currentVariant.systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundColor(isActive ? .brandAccent : .inkRecessiveSecondary)

                // "Has variants" affordance — small dot at the bottom-trailing
                // corner. Now appears on highlighter too (underline +
                // strikethrough variants).
                if category.variants.count > 1 {
                    Circle()
                        .fill(Color.inkRecessiveTertiary)
                        .frame(width: 3, height: 3)
                        .offset(x: 11, y: 11)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
        // Long-press → variant picker. `.highPriorityGesture` makes
        // the long-press resolve *before* the Button's internal tap
        // recogniser — so a hold reaches the variant picker without
        // racing the Button. Quick taps fail the 0.4s threshold and
        // still fall through to the Button's tap. The earlier
        // `.onLongPressGesture` form sat downstream of the Button
        // and never saw events on iOS 17+ because the Button's tap
        // gesture absorbed the press first.
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.4)
                .onEnded { _ in
                    guard category.variants.count > 1 else { return }
                    HapticManager.shared.contextMenuOpened()
                    openVariantCategory = category
                }
        )
        .accessibilityLabel(A11y.toolLabel(name: category.displayName, isActive: isActive))
        .accessibilityHint(A11y.toolHint)
        // Variant picker popover anchored to this button.
        .popover(
            isPresented: Binding(
                get: { openVariantCategory == category },
                set: { if !$0 { openVariantCategory = nil } }
            )
        ) {
            variantPicker(for: category)
                .presentationCompactAdaptation(.popover)
        }
    }

    private func handleCategoryTap(_ category: ToolCategory) {
        // Tap always activates the category's last-used variant.
        // Re-tapping an already-active category is a no-op (no flash,
        // no animation churn). The variant picker is opened via
        // long-press — see the gesture on `categoryButton`.
        let variant = ToolCategoryStore.lastVariant(for: category)
        guard viewModel.selectedTool.identity != variant else { return }
        withAnimation(.inkSpring(InkSpring.precise)) {
            viewModel.selectTool(identity: variant)
        }
        HapticManager.shared.toolSwitched()
    }

    @ViewBuilder
    private func variantPicker(for category: ToolCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.displayName)
                .font(.inkSubhead)
                .foregroundColor(.inkTextSecondary)
                .padding(.horizontal, Ink.Spacing.md)
                .padding(.top, Ink.Spacing.md)
                .padding(.bottom, Ink.Spacing.sm)

            ForEach(category.variants, id: \.rawValue) { variant in
                variantRow(variant, in: category)
                if variant != category.variants.last {
                    InkDivider()
                        .padding(.leading, Ink.Spacing.md + 22 + Ink.Spacing.sm)
                }
            }
        }
        .padding(.bottom, Ink.Spacing.sm)
        .frame(width: 220)
    }

    private func variantRow(_ variant: InkTool.Identity, in category: ToolCategory) -> some View {
        let isSelected = viewModel.selectedTool.identity == variant
        return Button {
            withAnimation(.inkSpring(InkSpring.precise)) {
                viewModel.selectTool(identity: variant)
            }
            HapticManager.shared.toolSwitched()
            openVariantCategory = nil
        } label: {
            HStack(spacing: Ink.Spacing.sm) {
                Image(systemName: variant.systemImage)
                    .font(.inkBody)
                    .foregroundColor(isSelected ? .inkAccentPrimary : .inkTextSecondary)
                    .frame(width: 22)
                Text(variant.displayName)
                    .font(.inkBody)
                    .foregroundColor(.inkTextPrimary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.inkAccentPrimary)
                }
            }
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
    }

    // MARK: Tool button

    @ViewBuilder
    private func toolButton(_ identity: InkTool.Identity) -> some View {
        let isActive = viewModel.selectedTool.identity == identity
        let core = Button {
            handleToolTap(identity)
        } label: {
            // Phase D: icon-colour-only active state (no filled pill).
            Image(systemName: identity.systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isActive ? .brandAccent : .inkRecessiveSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
        .accessibilityLabel(A11y.toolLabel(name: identity.displayName, isActive: isActive))
        .accessibilityHint(A11y.toolHint)

        // Eraser is the only tool with a variant picker today
        // (whole-stroke / pixel + erase-page). `.highPriorityGesture`
        // makes the long-press resolve before the Button's tap so a
        // hold reaches the picker; quick taps fail the threshold and
        // fall through to the tap action. The earlier
        // `.onLongPressGesture` placed after `.buttonStyle` never
        // received events on iOS 17+ — the Button's tap recogniser
        // consumed them first.
        if identity == .eraser {
            core
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            HapticManager.shared.contextMenuOpened()
                            showEraserPopover = true
                        }
                )
        } else {
            core
        }
    }

    private func handleToolTap(_ identity: InkTool.Identity) {
        // Tap always activates. Re-tapping an active tool is a no-op
        // — the eraser mode picker (formerly opened by tap-when-active)
        // moved to long-press. See `toolButton`.
        guard viewModel.selectedTool.identity != identity else { return }
        withAnimation(.inkSpring(InkSpring.precise)) {
            viewModel.selectTool(identity: identity)
        }
        HapticManager.shared.toolSwitched()
    }

    // identity.systemImage / identity.displayName replaced the old
    // iconName / toolName helpers — see InkTool.Identity.

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
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
    }

    // MARK: Size controls

    @ViewBuilder
    private var sizeControls: some View {
        switch edge.axis {
        case .vertical:
            VStack(spacing: 2) {
                sizeIncrementButton
                sizeValueButton
                sizeDecrementButton
            }
        case .horizontal:
            HStack(spacing: 2) {
                sizeDecrementButton
                sizeValueButton
                sizeIncrementButton
            }
        }
    }

    private var sizeIncrementButton: some View {
        Button {
            viewModel.incrementWidth()
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.inkRecessiveSecondary)
                .frame(width: buttonSize, height: buttonSize / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
        .disabled(!viewModel.selectedTool.hasWidth)
    }

    private var sizeValueButton: some View {
        Button {
            showSizePopover = true
        } label: {
            Text(formatWidth(viewModel.selectedTool.currentWidth))
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(.inkRecessiveSecondary)
                .monospacedDigit()
                .frame(width: buttonSize, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
    }

    private var sizeDecrementButton: some View {
        Button {
            viewModel.decrementWidth()
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.inkRecessiveSecondary)
                .frame(width: buttonSize, height: buttonSize / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.inkPressable)
        .disabled(!viewModel.selectedTool.hasWidth)
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
                Text("Adjust size in the toolbar.")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextTertiary)
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
        // Pixel eraser uses a different range and step than inking tools.
        let isPixelEraser: Bool = {
            if case .eraser(.pixel) = viewModel.selectedTool { return true }
            return false
        }()
        let range: ClosedRange<Double> = isPixelEraser ? 4...80 : 0.5...20
        let step:  Double               = isPixelEraser ? 1     : 0.5
        let title: String               = isPixelEraser ? "Eraser size" : "Width"

        return VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            Text(title)
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.selectedTool.currentWidth) },
                        set: { viewModel.setWidth(CGFloat($0)) }
                    ),
                    in: range,
                    step: step
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

    // MARK: Drag → snap-to-edge

    private var dragGesture: some Gesture {
        // Global coordinate space so the gesture's origin doesn't shift
        // as the palette repositions during the drag.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                // Follow the finger directly — no animation per tick.
                dragOffset = value.translation
            }
            .onEnded { value in
                let release = value.location          // global point of release
                let nearest = ToolbarEdge.nearestEdge(to: release, in: parentSize)

                // Per-notebook persistence — same key the view re-reads
                // on appear, so reopening the same notebook restores the
                // edge the user left it on.
                resolvedEdgeRaw = nearest.rawValue
                UserDefaults.standard.set(nearest.rawValue, forKey: positionKey)

                HapticManager.shared.dragReorderDropped()

                // Spring back. The dragOffset reset is what makes the pill
                // visually fly to its new edge — alignment is already updated.
                withAnimation(.inkSpring(InkSpring.snappy)) {
                    dragOffset = .zero
                }
            }
    }
}

import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Floating, edge-snapping pill of tools, current colour, and width controls.
///
/// Position model (Feature 5):
///   • The palette anchors to one of four edges (`ToolbarEdge`).
///   • Edge is persisted **per orientation** in two `@AppStorage` keys.
///   • Layout switches automatically: top/bottom → HStack, left/right → VStack.
///   • Dragging follows the finger; releasing snaps to the nearest edge for
///     the *current* orientation, animated with `CeciliasNotesSpring.snappy`.
struct ToolPaletteView: View {
    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme

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
    @State private var showImageVariantPopover = false
    /// Drives the long-press variant menu on the lasso tool
    /// (freeform vs marquee). Step 9.
    @State private var showLassoVariantPopover = false
    /// Mirrored from `LassoSelectionState.shared.mode` so the
    /// popover's check-marks update without subscribing the whole
    /// palette to the singleton.
    @State private var lassoMode: LassoMath.Mode = LassoSelectionState.shared.mode
    /// Mirror of `ImageToolVariantStore.current` for SwiftUI redraw.
    /// Kept in sync via the `.imageToolVariantChanged` notification so
    /// taps on the variant picker update the toolbar glyph immediately.
    @State private var imageVariant: ImageToolVariant = ImageToolVariantStore.current

    // MARK: - Step 4.5: PDF-as-reference (Workflow B)
    /// URL handed back from the document picker, drives the
    /// `PDFPagePickerSheet` presentation. Cleared on dismiss.
    /// Step 7.2 retired the SwiftUI `.fileImporter` flag — the
    /// document picker now goes through `MediaPickerPresenter`
    /// (UIKit-direct) so it survives editor-cover transitions.
    @State private var pdfPickerSourceURL: URL?
    /// Which category, if any, is showing its variant picker popover.
    @State private var openVariantCategory: ToolCategory?
    /// Identity of the tool whose tap-when-active customization
    /// popover is currently open. Drives the per-tool popover that
    /// replaced the always-visible color + width strip — the panel
    /// only shows up when the user explicitly re-taps a selected
    /// tool, so tools without customization (cursor, image, ruler,
    /// sticky-note, text) stay out of the way.
    @State private var openCustomizeTool: CeciliasNotesTool.Identity?

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
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy), value: edge)
        // Re-flow the palette when the header slides in or out so a
        // top-edge palette doesn't end up sitting under the cover-tone
        // header, and snaps back into place when the header hides.
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy),
                   value: viewModel.headerVisibility.isHeaderVisible)
        .onAppear {
            // Hydrate from per-notebook UserDefaults on first paint.
            if let stored = UserDefaults.standard.string(forKey: positionKey) {
                resolvedEdgeRaw = stored
            }
            // Re-read the image variant on appear in case Settings or a
            // different surface changed it while the editor wasn't on
            // screen.
            imageVariant = ImageToolVariantStore.current
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .imageToolVariantChanged)
        ) { _ in
            imageVariant = ImageToolVariantStore.current
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
        // Page-picker sheet. Driven by `pdfPickerSourceURL` being
        // non-nil after the file importer hands back a PDF.
        .sheet(item: Binding(
            get: { pdfPickerSourceURL.map { PDFPickerSourceWrapper(url: $0) } },
            set: { if $0 == nil { pdfPickerSourceURL = nil } }
        )) { wrapper in
            PDFPagePickerSheet(
                sourceURL: wrapper.url,
                onConfirm: { indices, destination in
                    let url = wrapper.url
                    pdfPickerSourceURL = nil
                    Task {
                        await PDFReferenceImporter.importPages(
                            from: url,
                            pageIndices: indices,
                            into: viewModel,
                            destination: destination
                        )
                    }
                },
                onCancel: { pdfPickerSourceURL = nil }
            )
        }
    }

    /// Wrapper so the URL can drive `.sheet(item:)`'s `Identifiable`
    /// requirement without subclassing URL itself.
    private struct PDFPickerSourceWrapper: Identifiable {
        let url: URL
        var id: String { url.path }
    }

    // MARK: Layout

    /// The pill itself. Lays out as HStack or VStack depending on `edge.axis`.
    @ViewBuilder
    private var paletteBody: some View {
        let content = paletteContents
        switch edge.axis {
        case .vertical:
            VStack(spacing: CeciliasNotes.Spacing.xs) { content }
                .padding(.vertical, CeciliasNotes.Spacing.sm)
                .frame(width: paletteThickness)
                .background(paletteBackground)
        case .horizontal:
            HStack(spacing: CeciliasNotes.Spacing.xs) { content }
                .padding(.horizontal, CeciliasNotes.Spacing.sm)
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

        // Step 2: cursor is the first tool in the palette — the
        // neutral interaction mode (no strokes, finger selects
        // content). Sits before any drawing tool so the eye reads
        // "default state" → "writing tools" → "modes".
        toolButton(.cursor)

        divider

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
        // Step 5.5: sticky-note tool surfaces unconditionally.
        // The V5 gate (`Notebook.isPDFBacked`) was retired with
        // the PDF-notebook refactor; the sticky surface works on
        // any page. Step 7 (sticky migration) can revisit
        // visibility heuristics if needed.
        toolButton(.stickyNote)

        // Per-tool customization (color / width / mode) used to live
        // here as an always-visible strip — it cluttered the pill for
        // tools that have no meaningful options (text, image, ruler,
        // sticky-note, cursor). The strip is now a popover surfaced
        // by re-tapping a selected tool. See `handleToolTap` /
        // `handleCategoryTap` for the trigger and
        // `customizePopover(for:)` for the per-tool content.
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
                                 ? theme.accent
                                 : theme.recessiveSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
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
            .fill(theme.recessiveTertiary)
            .frame(width: 2, height: 2)
    }

    // MARK: Background

    private var paletteBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(theme.surfaceElevated.opacity(0.96))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(theme.recessiveQuaternary, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, x: 0, y: 2)
    }

    @ViewBuilder
    private var divider: some View {
        switch edge.axis {
        case .vertical:
            Rectangle()
                .fill(theme.borderSubtle)
                .frame(width: paletteThickness - 16, height: 0.5)
        case .horizontal:
            Rectangle()
                .fill(theme.borderSubtle)
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
                    .foregroundColor(isActive ? theme.accent : theme.recessiveSecondary)

                // "Has variants" affordance — small dot at the bottom-trailing
                // corner. Now appears on highlighter too (underline +
                // strikethrough variants).
                if category.variants.count > 1 {
                    Circle()
                        .fill(theme.recessiveTertiary)
                        .frame(width: 3, height: 3)
                        .offset(x: 11, y: 11)
                }
            }
            .frame(width: buttonSize, height: buttonSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
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
        // Re-tap customize popover (color + width). Driven by
        // `openCustomizeTool`; matches when the open identity
        // belongs to this category's variants.
        .popover(
            isPresented: Binding(
                get: {
                    guard let id = openCustomizeTool else { return false }
                    return category.variants.contains(id)
                },
                set: { if !$0 { openCustomizeTool = nil } }
            )
        ) {
            if let id = openCustomizeTool {
                customizePopover(for: id)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    private func handleCategoryTap(_ category: ToolCategory) {
        // Tap activates the category's last-used variant. When the
        // tool is already active, re-tapping opens the customize
        // popover (color / width / opacity) instead — the always-on
        // customization strip is gone, so this re-tap is now the
        // single discoverable affordance for those options.
        let variant = ToolCategoryStore.lastVariant(for: category)
        if viewModel.selectedTool.identity == variant {
            openCustomizeTool = variant
            HapticManager.shared.contextMenuOpened()
            return
        }
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) {
            viewModel.selectTool(identity: variant)
        }
        HapticManager.shared.toolSwitched()
    }

    @ViewBuilder
    private func variantPicker(for category: ToolCategory) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.displayName)
                .font(.ceciliasNotesSubhead)
                .foregroundColor(theme.foregroundMuted)
                .padding(.horizontal, CeciliasNotes.Spacing.md)
                .padding(.top, CeciliasNotes.Spacing.md)
                .padding(.bottom, CeciliasNotes.Spacing.sm)

            ForEach(category.variants, id: \.rawValue) { variant in
                variantRow(variant, in: category)
                if variant != category.variants.last {
                    CeciliasNotesDivider()
                        .padding(.leading, CeciliasNotes.Spacing.md + 22 + CeciliasNotes.Spacing.sm)
                }
            }
        }
        .padding(.bottom, CeciliasNotes.Spacing.sm)
        .frame(width: 220)
    }

    private func variantRow(_ variant: CeciliasNotesTool.Identity, in category: ToolCategory) -> some View {
        let isSelected = viewModel.selectedTool.identity == variant
        return Button {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) {
                viewModel.selectTool(identity: variant)
            }
            HapticManager.shared.toolSwitched()
            openVariantCategory = nil
        } label: {
            HStack(spacing: CeciliasNotes.Spacing.sm) {
                Image(systemName: variant.systemImage)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(isSelected ? theme.accent : theme.foregroundMuted)
                    .frame(width: 22)
                Text(variant.displayName)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(theme.foreground)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
    }

    // MARK: Tool button

    @ViewBuilder
    private func toolButton(_ identity: CeciliasNotesTool.Identity) -> some View {
        let isActive = viewModel.selectedTool.identity == identity
        // The image button's glyph follows the persisted variant
        // (`tool.image.variant`), so the user can see whether a tap
        // will open the camera or the photo library before they tap.
        let glyph: String = identity == .image ? imageVariant.systemImage : identity.systemImage
        let core = Button {
            handleToolTap(identity)
        } label: {
            // Phase D: icon-colour-only active state (no filled pill).
            Image(systemName: glyph)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(isActive ? theme.accent : theme.recessiveSecondary)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
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
                .popover(isPresented: $showEraserPopover) {
                    eraserPopover
                        .presentationCompactAdaptation(.popover)
                }
        } else if identity == .lasso {
            // Step 9: long-press opens the freeform / marquee
            // mode picker. Tap selects the lasso tool using the
            // last-used mode — persisted via UserDefaults inside
            // `LassoSelectionState`.
            core
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            HapticManager.shared.contextMenuOpened()
                            showLassoVariantPopover = true
                        }
                )
                .popover(isPresented: $showLassoVariantPopover) {
                    lassoVariantPopover
                        .presentationCompactAdaptation(.popover)
                }
        } else if identity == .image {
            // Long-press on the image button opens the variant picker
            // (photo library / camera). Tap selects the image tool AND
            // opens the picker matching the persisted variant — the
            // captured image lands at page centre via the standard
            // imageImportRequested → imageImportCompleted chain.
            core
                .highPriorityGesture(
                    LongPressGesture(minimumDuration: 0.4)
                        .onEnded { _ in
                            HapticManager.shared.contextMenuOpened()
                            showImageVariantPopover = true
                        }
                )
                .popover(isPresented: $showImageVariantPopover) {
                    imageVariantPopover
                        .presentationCompactAdaptation(.popover)
                }
        } else {
            core
        }
    }

    // MARK: Lasso-tool variant picker

    /// Freeform / marquee mode picker. Mirrors the eraser /
    /// image variant popovers — two rows, current selection shows
    /// a check-mark.
    private var lassoVariantPopover: some View {
        VStack(spacing: 0) {
            ForEach(LassoMath.Mode.allCases, id: \.self) { mode in
                Button {
                    LassoSelectionState.shared.mode = mode
                    lassoMode = mode
                    showLassoVariantPopover = false
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: mode == .freeform
                              ? "lasso"
                              : "rectangle.dashed")
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(theme.foreground)
                            .frame(width: 22)
                        Text(mode == .freeform ? "Freeform" : "Marquee")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(theme.foreground)
                        Spacer(minLength: 12)
                        if lassoMode == mode {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(minWidth: 200)
        .background(theme.surfaceElevated)
    }

    // MARK: Image-tool variant picker

    /// Photo Library / Camera / PDF Page picker shown by long-pressing
    /// the image tool button. The first two rows pick an
    /// `ImageToolVariant` (persisted; the next tap on the button
    /// fires that source). The third row — PDF Page — opens the
    /// document picker that drives Workflow B (PDF-as-reference),
    /// independent of the persisted variant: PDF references are
    /// always a deliberate action, never a single-tap default.
    private var imageVariantPopover: some View {
        VStack(spacing: 0) {
            ForEach(ImageToolVariant.allCases, id: \.self) { variant in
                Button {
                    ImageToolVariantStore.current = variant
                    imageVariant = variant
                    showImageVariantPopover = false
                    requestImageImport(source: variant.importSource)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: variant.systemImage)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundStyle(theme.foreground)
                            .frame(width: 22)
                        Text(variant.displayName)
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(theme.foreground)
                        Spacer(minLength: 12)
                        if variant == imageVariant {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            // Step 4.5: PDF Page (Workflow B). Sits below the
            // variant rows separated by a subtle divider so users
            // see it as "another source" rather than a variant
            // toggle. Tap opens the document picker; PDF selection
            // chains into the page-picker sheet, then the importer.
            CeciliasNotesDivider()
            Button {
                showImageVariantPopover = false
                // Step 7.2: UIKit-direct UIDocumentPickerViewController
                // via `MediaPickerPresenter`. Replaces the SwiftUI
                // `.fileImporter` that flaked when the editor cover's
                // hosting controller was mid-transition. Picker
                // presents on the next runloop tick (built into the
                // presenter) so the popover finishes dismissing first.
                MediaPickerPresenter.presentPDFDocumentPicker(
                    completion: { url in
                        pdfPickerSourceURL = url
                    },
                    onCancel: {
                        pdfPickerSourceURL = nil
                    }
                )
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(theme.foreground)
                        .frame(width: 22)
                    Text("PDF Page")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(theme.foreground)
                    Spacer(minLength: 12)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 220)
    }

    /// Post the centre-of-page image-import request used by both the
    /// tool-button tap and the long-press variant picker.
    private func requestImageImport(source: ImageImportSource) {
        #if DEBUG
        dlog("[ImagePicker] presenting picker, reason=user explicit tap on image tool icon source=\(source.rawValue)")
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: "\n  ")
        dlog("[ImagePicker]   stack:\n  \(stack)")
        #endif
        NotificationCenter.default.post(
            name: .imageImportRequested,
            object: nil,
            userInfo: [
                ImageImportUserInfoKey.normalizedX: 0.5,
                ImageImportUserInfoKey.normalizedY: 0.5,
                ImageImportUserInfoKey.source:      source.rawValue,
            ]
        )
    }

    private func handleToolTap(_ identity: CeciliasNotesTool.Identity) {
        // The image button is special: every tap (active or not) fires
        // the picker matching the persisted variant in addition to
        // selecting the tool. This collapses the previous two-step
        // "select tool, then tap canvas" flow into a single tap, which
        // matches the spec for Feature 6.
        if identity == .image {
            if viewModel.selectedTool.identity != .image {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) {
                    viewModel.selectTool(identity: .image)
                }
            }
            HapticManager.shared.toolSwitched()
            requestImageImport(source: imageVariant.importSource)
            return
        }
        // Tap activates. Re-tapping an active tool opens its
        // customization popover (eraser → mode + width, lasso →
        // freeform/marquee, text → no popover today). Tools with no
        // meaningful options stay inert on re-tap. The eraser's
        // long-press popover is retained as an alternate path so
        // muscle memory from the previous flow still works.
        if viewModel.selectedTool.identity == identity {
            // Re-tap on the already-selected tool opens its
            // customization popover. Eraser and lasso route through
            // their existing per-button popovers (so a long-press
            // and a tap-when-active reach the same panel); other
            // tools have no customize popover and the tap no-ops.
            switch identity {
            case .eraser:
                showEraserPopover = true
                HapticManager.shared.contextMenuOpened()
            case .lasso:
                showLassoVariantPopover = true
                HapticManager.shared.contextMenuOpened()
            default:
                break
            }
            return
        }
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.precise)) {
            viewModel.selectTool(identity: identity)
        }
        HapticManager.shared.toolSwitched()
    }

    // MARK: Customize popover (re-tap selected tool)

    /// Per-tool customization content shown when the user re-taps
    /// the selected tool. Inking tools get color + width; eraser
    /// gets its existing mode popover; lasso gets the freeform /
    /// marquee picker. Tools without options fall through to an
    /// empty view (the popover only opens when content exists).
    @ViewBuilder
    private func customizePopover(for identity: CeciliasNotesTool.Identity) -> some View {
        if identity == .eraser {
            eraserPopover
        } else if identity == .lasso {
            lassoVariantPopover
        } else if viewModel.selectedTool.hasColour || viewModel.selectedTool.hasWidth {
            inkingCustomizePopover
        } else {
            EmptyView()
        }
    }

    /// Color swatch + opacity + width for pen / pencil / brush /
    /// highlighter. The popover wraps `ColorPickerView`, which now
    /// owns the colour swatches, opacity and width sections in one
    /// 320pt-wide panel — fixes the earlier "outer wrapper at 260pt
    /// + inner ColorPickerView at 300pt clipped every label" bug.
    private var inkingCustomizePopover: some View {
        ColorPickerView(viewModel: viewModel) {
            openCustomizeTool = nil
        }
    }

    // identity.systemImage / identity.displayName replaced the old
    // iconName / toolName helpers — see CeciliasNotesTool.Identity.

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
                        .strokeBorder(theme.borderDefault, lineWidth: 0.5)
                )
                .opacity(viewModel.selectedTool.hasColour ? 1 : 0.3)
                .frame(width: buttonSize, height: buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .popover(isPresented: $viewModel.isShowingColorPicker) {
            ColorPickerView(viewModel: viewModel) {
                viewModel.isShowingColorPicker = false
            }
        }
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
                .foregroundColor(theme.recessiveSecondary)
                .frame(width: buttonSize, height: buttonSize / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .disabled(!viewModel.selectedTool.hasWidth)
    }

    private var sizeValueButton: some View {
        Button {
            showSizePopover = true
        } label: {
            Text(formatWidth(viewModel.selectedTool.currentWidth))
                .font(.system(size: 10, weight: .regular))
                .foregroundColor(theme.recessiveSecondary)
                .monospacedDigit()
                .frame(width: buttonSize, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
        .popover(isPresented: $showSizePopover) {
            sizePopover
                .presentationCompactAdaptation(.popover)
        }
    }

    private var sizeDecrementButton: some View {
        Button {
            viewModel.decrementWidth()
        } label: {
            Image(systemName: "minus")
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(theme.recessiveSecondary)
                .frame(width: buttonSize, height: buttonSize / 2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
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
        return VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            Text("Eraser")
                .font(.ceciliasNotesSubhead)
                .foregroundColor(theme.foregroundMuted)

            VStack(spacing: 0) {
                eraserModeRow(.wholeStroke, isSelected: activeMode == .wholeStroke)
                Divider()
                eraserModeRow(.pixel,       isSelected: activeMode == .pixel)
                Divider()
                erasePageRow
            }
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))

            if activeMode == .pixel {
                pixelEraserSizeRow
            }
        }
        .padding(CeciliasNotes.Spacing.md)
        .frame(width: 260)
    }

    /// Tip-size slider for the pixel (bitmap) eraser. Backed by
    /// `EditorViewModel.pixelEraserWidth`, which persists to the
    /// shared UserDefaults key `CeciliasNotesTool.makePKTool` reads.
    private var pixelEraserSizeRow: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.xs) {
            HStack {
                Text("Size")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
                Spacer()
                Text("\(Int(viewModel.pixelEraserWidth))")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foreground)
                    .monospacedDigit()
            }
            Slider(
                value: Binding(
                    get: { Double(viewModel.pixelEraserWidth) },
                    set: { viewModel.pixelEraserWidth = CGFloat($0) }
                ),
                in: 4...80,
                step: 1
            )
            .tint(theme.accent)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
        .padding(.vertical, CeciliasNotes.Spacing.sm)
    }

    private func eraserModeRow(_ mode: EraserMode, isSelected: Bool) -> some View {
        Button {
            viewModel.selectedTool = .eraser(mode: mode)
        } label: {
            HStack {
                Image(systemName: mode.iconName)
                    .frame(width: 22)
                Text(mode.displayName)
                    .font(.ceciliasNotesBody)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(theme.accent)
                }
            }
            .foregroundColor(theme.foreground)
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
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
                    .font(.ceciliasNotesBody)
                Spacer()
            }
            .foregroundColor(theme.danger)
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(.ceciliasNotesPressable)
    }

    private var sizePopover: some View {
        // Pixel eraser used to take a different range here; its
        // configurable width was retired (Settings slider removed,
        // `hasWidth` is now false for `.eraser(.pixel)`), so the
        // popover only ever serves inking tools now.
        let range: ClosedRange<Double> = 0.5...20
        let step:  Double               = 0.5
        let title: String               = "Width"

        return VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            Text(title)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
            HStack {
                Slider(
                    value: Binding(
                        get: { Double(viewModel.selectedTool.currentWidth) },
                        set: { viewModel.setWidth(CGFloat($0)) }
                    ),
                    in: range,
                    step: step
                )
                .tint(theme.accent)
                Text(formatWidth(viewModel.selectedTool.currentWidth))
                    .font(.ceciliasNotesSubhead)
                    .foregroundColor(theme.foreground)
                    .monospacedDigit()
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(CeciliasNotes.Spacing.md)
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
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    dragOffset = .zero
                }
            }
    }
}

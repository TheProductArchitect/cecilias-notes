import Combine
import SwiftUI
import UIKit

// MARK: - TextBlockOverlayView

/// SwiftUI view that renders all TextBlock items for the current page
/// as positioned overlays on top of the canvas. Installed inside the
/// canvas contentView so it participates in the same coordinate space
/// and zoom/scroll as the PKCanvasView.
///
/// Interaction model (enforced by TextModeGestureController):
///   • Finger tap on empty space (text mode) → no-op (drag required)
///   • Finger drag on empty space (text mode) → drag-to-create box;
///     dashed preview during drag, commits a new block on release
///     (clamped to a 100×30pt minimum, width locked, height grows
///     as the user types)
///   • Finger tap inside idle block → select it
///   • Finger tap inside selected block → begin editing
///   • Finger drag on idle block → move it
///   • Finger drag on selected block outside handles → move it
struct TextBlockOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    @Environment(\.theme) private var theme
    /// Page this overlay is mounted on. Per-page mount per Phase 3b —
    /// renders only blocks whose `pageId` matches.
    let pageId: UUID
    /// Single placement primitive — base size only. See
    /// `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.A.
    let coordinateSpace: PageCoordinateSpace

    @State private var activeBlockId: UUID?
    @State private var interactionStates: [UUID: TextBlockInteractionState] = [:]
    @State private var layouts: [UUID: TextBlockLayoutState] = [:]
    @State private var blockHeights: [UUID: CGFloat] = [:]

    // Move gesture tracking
    @State private var moveStartNorm: CGPoint?

    // Resize gesture tracking
    @State private var resizeStartRect: CGRect?

    // Drag-to-create-box gesture tracking. `dragCreateStart` holds the
    // touch-down point (in point coords); `dragCreateCurrent` updates on
    // every drag event. When both are set, the dashed-preview rect is
    // rendered between them. Cleared on drag end / cancel.
    @State private var dragCreateStart:   CGPoint?
    @State private var dragCreateCurrent: CGPoint?

    // Link popover
    @State private var isShowingLinkPopover: Bool = false
    @State private var linkPopoverBlockId: UUID?
    @State private var linkPopoverRange: NSRange = NSRange()
    @State private var linkPopoverExistingURL: URL?

    // Keyboard offset — kept in sync with EditorViewModel
    @State private var keyboardOffset: CGFloat = 0

    /// Blocks scoped to this overlay's page. Resolved through
    /// `viewModel.pages` rather than the storage layer so SwiftData's
    /// observation drives re-renders. Lecture-prefixed blocks
    /// (`content.hasPrefix("lecture:")`) are filtered out — those
    /// render via `LectureBlocksOverlayView` on the same page.
    private var blocks: [TextBlock] {
        guard let page = viewModel.pages.first(where: { $0.id == pageId })
        else { return [] }
        return (page.textBlocks ?? [])
            .filter { !$0.isDeleted && !$0.content.hasPrefix("lecture:") }
            .sorted { $0.zIndex < $1.zIndex }
    }

    var body: some View {
        let pageSize = coordinateSpace.baseSize
        let blocks   = self.blocks

        ZStack(alignment: .topLeading) {
            // Transparent drag-to-create-box catcher. Single tap does
            // nothing — the user must drag out a rectangle. The
            // gesture commits a new text block sized to the drag on
            // release, snapping to the 100×30pt minimum.
            if viewModel.selectedTool.isTextMode {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(dragCreateGesture(pageSize: pageSize))
            }

            // Background tap-outside-to-clear. Only mounted when at
            // least one block is selected or editing — without the
            // guard this would absorb every tap on the page and
            // starve the overlays below it. The previous version of
            // the code documented this clear layer in a comment on
            // line 191 but never actually added it; the result was
            // a selected text block (often from an MCP-authored
            // notebook) that the user couldn't deselect by tapping
            // elsewhere on the page.
            if hasInteractiveBlock {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { deselectAll() }
            }

            ForEach(blocks, id: \.id) { block in
                blockView(block: block, pageSize: pageSize)
            }

            // Dashed live preview while the user is dragging out a
            // new text-box rectangle. Drawn on top so it visually
            // commits even if it overlaps existing blocks.
            if let start = dragCreateStart, let current = dragCreateCurrent {
                let rect = previewRect(start: start, current: current)
                Rectangle()
                    .strokeBorder(
                        theme.accent,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onAppear { syncLayouts() }
        // Link popover sheet
        .sheet(isPresented: $isShowingLinkPopover) {
            if let blockId = linkPopoverBlockId,
               let block = blocks.first(where: { $0.id == blockId }) {
                LinkPopoverView(
                    isPresented: $isShowingLinkPopover,
                    existingURL: linkPopoverExistingURL,
                    onApply: { url in applyLink(url, to: block, range: linkPopoverRange) },
                    onRemove: { removeLink(from: block, range: linkPopoverRange) }
                )
                .presentationDetents([.height(180)])
                .presentationDragIndicator(.hidden)
            }
        }
    }

    // MARK: - Block view

    @ViewBuilder
    private func blockView(block: TextBlock, pageSize: CGSize) -> some View {
        let layout  = layouts[block.id] ?? TextBlockLayoutState(from: block)
        let state   = interactionStates[block.id] ?? .idle
        let ptRect  = layout.pointRect(pageSize: pageSize)
        let height  = blockHeights[block.id] ?? ptRect.height

        // Step 5: `LectureBlockView` removed alongside the
        // `LectureRecord` entity. Legacy `lecture:<uuid>`-prefixed
        // TextBlocks (none exist in V6 — wipe-and-rebuild) would
        // render as plain text via the `else` branch below; no
        // routing needed.
        if false {
            EmptyView()
        } else {
            VStack(spacing: 0) {
                TextBlockView(
                    block:            block,
                    pageSize:         pageSize,
                    interactionState: state,
                    onHeightChange: { newHeight in
                        blockHeights[block.id] = newHeight
                    },
                    onCommit: { attrString in
                        commitBlock(block, attrString: attrString, layout: layout)
                    },
                    onBecomeActive: {
                        activateBlock(block)
                    },
                    onRequestLink: { range in
                        presentLinkPopover(for: block, range: range)
                    },
                    onRequestNextBlock: {
                        focusNextTextBlock(after: block.id)
                    },
                    onRequestPreviousBlock: {
                        focusPreviousTextBlock(before: block.id)
                    }
                )
            }
            .frame(width: ptRect.width, height: height)
            .background(blockBackground(state: state))
            .overlay(blockBorder(state: state))
            .position(x: ptRect.midX, y: ptRect.minY + height / 2)
            .gesture(moveGesture(block: block, pageSize: pageSize))
            .onTapGesture {
                handleTap(on: block)
            }
            .overlay {
                if state == .selected {
                    ResizeHandlesView(
                        pageSize: pageSize,
                        pointRect: CGRect(x: ptRect.origin.x, y: ptRect.minY,
                                         width: ptRect.width, height: height),
                        onResize: { handle, translation in
                            handleResize(block: block, handle: handle,
                                         translation: translation, pageSize: pageSize)
                        },
                        onResizeEnded: {
                            commitLayout(block: block, pageSize: pageSize)
                        }
                    )
                }
            }
            // Deselect on tap outside — captured by the ZStack's clear layer below
        }
    }

    // MARK: - Backgrounds / borders

    @ViewBuilder
    private func blockBackground(state: TextBlockInteractionState) -> some View {
        if state == .editing {
            theme.surfaceElevated.opacity(0.92)
        } else if state == .selected {
            theme.accent.opacity(0.04)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func blockBorder(state: TextBlockInteractionState) -> some View {
        if state == .editing {
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 1)
        } else if state == .selected {
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .strokeBorder(theme.accent.opacity(0.5), lineWidth: 1)
        } else {
            EmptyView()
        }
    }

    // MARK: - Tap handling

    private func handleTap(on block: TextBlock) {
        let current = interactionStates[block.id] ?? .idle
        deselectAll(except: block.id)
        switch current {
        case .idle:
            interactionStates[block.id] = .selected
            activeBlockId = block.id
        case .selected:
            interactionStates[block.id] = .editing
            activeBlockId = block.id
        case .editing:
            break
        }
    }

    private func activateBlock(_ block: TextBlock) {
        interactionStates[block.id] = .editing
        activeBlockId = block.id
    }

    private func deselectAll(except id: UUID? = nil) {
        for key in interactionStates.keys where key != id {
            interactionStates[key] = .idle
        }
    }

    /// True when at least one block is in a non-idle state
    /// (selected or editing). Gates the full-page tap-outside
    /// catcher so it's only mounted when there's a selection to
    /// dismiss.
    private var hasInteractiveBlock: Bool {
        interactionStates.values.contains(where: { $0 != .idle })
    }

    // MARK: - Move gesture

    private func moveGesture(block: TextBlock, pageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if moveStartNorm == nil {
                    let layout = layouts[block.id] ?? TextBlockLayoutState(from: block)
                    moveStartNorm = layout.normalizedRect.origin
                }
                guard let start = moveStartNorm else { return }
                let dx = value.translation.width  / pageSize.width
                let dy = value.translation.height / pageSize.height
                var layout = layouts[block.id] ?? TextBlockLayoutState(from: block)
                layout.normalizedRect.origin = CGPoint(
                    x: max(0, min(1 - layout.normalizedRect.width,  start.x + dx)),
                    y: max(0, min(1 - layout.normalizedRect.height, start.y + dy))
                )
                layouts[block.id] = layout
            }
            .onEnded { _ in
                moveStartNorm = nil
                commitLayout(block: block, pageSize: pageSize)
            }
    }

    // MARK: - Resize

    private func handleResize(block: TextBlock, handle: ResizeHandle,
                               translation: CGPoint, pageSize: CGSize) {
        if resizeStartRect == nil {
            resizeStartRect = (layouts[block.id] ?? TextBlockLayoutState(from: block)).normalizedRect
        }
        guard let start = resizeStartRect else { return }
        let dx = translation.x / pageSize.width
        let dy = translation.y / pageSize.height

        var newRect = start
        let minDim: CGFloat = 48 / max(pageSize.width, pageSize.height)

        if handle.movesLeft   { newRect.origin.x  = min(start.maxX - minDim, start.origin.x + dx)
                                newRect.size.width = start.maxX - newRect.origin.x }
        if handle.movesRight  { newRect.size.width  = max(minDim, start.width + dx) }
        if handle.movesTop    { newRect.origin.y  = min(start.maxY - minDim, start.origin.y + dy)
                                newRect.size.height = start.maxY - newRect.origin.y }
        if handle.movesBottom { newRect.size.height = max(minDim, start.height + dy) }

        var layout = layouts[block.id] ?? TextBlockLayoutState(from: block)
        layout.normalizedRect = newRect
        layouts[block.id] = layout
    }

    // MARK: - Block creation

    /// Minimum drag-out text-box size in points. Anything smaller
    /// (including a stray tap that never moves) snaps up to this.
    private static let minBoxWidthPt:  CGFloat = 100
    private static let minBoxHeightPt: CGFloat = 30

    /// Drag-to-create text box gesture. `minimumDistance: 4` so a
    /// stationary tap doesn't accidentally commit a min-sized box; the
    /// gesture has to feel like a deliberate drag before the dashed
    /// preview appears.
    private func dragCreateGesture(pageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if dragCreateStart == nil {
                    dragCreateStart = value.startLocation
                    deselectAll()
                }
                dragCreateCurrent = value.location
            }
            .onEnded { value in
                defer {
                    dragCreateStart   = nil
                    dragCreateCurrent = nil
                }
                guard let start = dragCreateStart else { return }
                let raw = previewRect(start: start, current: value.location)
                createBlock(fromPointRect: raw, pageSize: pageSize)
            }
    }

    /// Build the point-space preview rectangle from the touch-down
    /// point and the current drag location, applying the minimum-size
    /// floor and clamping to the page bounds. Used for both the dashed
    /// preview and the final committed rect so the on-screen preview
    /// matches the persisted block exactly.
    private func previewRect(start: CGPoint, current: CGPoint) -> CGRect {
        let x = min(start.x, current.x)
        let y = min(start.y, current.y)
        let w = max(Self.minBoxWidthPt,  abs(current.x - start.x))
        let h = max(Self.minBoxHeightPt, abs(current.y - start.y))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Commit a new TextBlock at the dragged rectangle. Height grows
    /// from this seed as the user types — width is locked by the drag,
    /// so text wraps inside it.
    private func createBlock(fromPointRect ptRect: CGRect, pageSize: CGSize) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        let clampedW = min(ptRect.width,  pageSize.width)
        let clampedH = min(ptRect.height, pageSize.height)
        let clampedX = max(0, min(pageSize.width  - clampedW, ptRect.origin.x))
        let clampedY = max(0, min(pageSize.height - clampedH, ptRect.origin.y))
        let normRect = CGRect(
            x:      Double(clampedX) / Double(pageSize.width),
            y:      Double(clampedY) / Double(pageSize.height),
            width:  Double(clampedW) / Double(pageSize.width),
            height: Double(clampedH) / Double(pageSize.height)
        )
        guard let block = viewModel.createTextBlock(onPageId: pageId, at: normRect) else {
            #if DEBUG
            dlog("[TextTool] viewModel.createTextBlock returned nil — storage refused")
            #endif
            return
        }
        #if DEBUG
        dlog("[TextTool] TextBlock created id=\(block.id) rect=\(normRect) — entering editing state")
        #endif
        layouts[block.id] = TextBlockLayoutState(from: block)
        interactionStates[block.id] = .editing
        activeBlockId = block.id
    }

    // MARK: - Commit

    private func commitBlock(_ block: TextBlock, attrString: NSAttributedString,
                              layout: TextBlockLayoutState) {
        let rect = layout.normalizedRect
        viewModel.updateTextBlock(block, richText: attrString, rect: rect)
    }

    private func commitLayout(block: TextBlock, pageSize: CGSize) {
        resizeStartRect = nil
        guard let layout = layouts[block.id] else { return }
        let attrText: NSAttributedString
        if let data = block.richTextData,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            attrText = decoded
        } else {
            attrText = NSAttributedString(string: block.content)
        }
        viewModel.updateTextBlock(block, richText: attrText, rect: layout.normalizedRect)
    }

    // MARK: - Link helpers

    private func presentLinkPopover(for block: TextBlock, range: NSRange) {
        linkPopoverBlockId = block.id
        linkPopoverRange   = range
        if let data = block.richTextData,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
            linkPopoverExistingURL = RichTextAttributes.linkURL(in: decoded, at: max(0, range.location))
        }
        isShowingLinkPopover = true
    }

    private func applyLink(_ url: URL, to block: TextBlock, range: NSRange) {
        guard let data    = block.richTextData,
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        else { return }
        let mutable = NSMutableAttributedString(attributedString: decoded)
        RichTextAttributes.applyLink(url, to: mutable, range: range)
        viewModel.updateTextBlock(block, richText: mutable, rect: nil)
    }

    private func removeLink(from block: TextBlock, range: NSRange) {
        guard let data    = block.richTextData,
              let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data)
        else { return }
        let mutable = NSMutableAttributedString(attributedString: decoded)
        RichTextAttributes.removeLink(from: mutable, range: range)
        viewModel.updateTextBlock(block, richText: mutable, rect: nil)
    }

    // MARK: - Sync

    private func syncLayouts() {
        let pageBlocks = blocks
        for block in pageBlocks {
            if layouts[block.id] == nil {
                layouts[block.id] = TextBlockLayoutState(from: block)
            }
        }
        // Remove stale entries
        let ids = Set(pageBlocks.map(\.id))
        layouts.keys.filter { !ids.contains($0) }.forEach { layouts.removeValue(forKey: $0) }
        interactionStates.keys.filter { !ids.contains($0) }.forEach { interactionStates.removeValue(forKey: $0) }
        blockHeights.keys.filter { !ids.contains($0) }.forEach { blockHeights.removeValue(forKey: $0) }
    }

    // MARK: - Coordinate helpers

    private func normalise(_ point: CGPoint, pageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x / pageSize.width, y: point.y / pageSize.height)
    }

    // MARK: - Focus navigation (Tab / Shift+Tab outside a list)

    /// Activates editing on the next text block by ascending zIndex.
    private func focusNextTextBlock(after currentBlockId: UUID) {
        let pageBlocks = blocks
        guard let idx = pageBlocks.firstIndex(where: { $0.id == currentBlockId }),
              idx + 1 < pageBlocks.count else { return }
        let nextBlock = pageBlocks[idx + 1]
        deselectAll(except: nextBlock.id)
        interactionStates[nextBlock.id] = .editing
        activeBlockId = nextBlock.id
    }

    /// Activates editing on the previous text block by descending zIndex.
    private func focusPreviousTextBlock(before currentBlockId: UUID) {
        let pageBlocks = blocks
        guard let idx = pageBlocks.firstIndex(where: { $0.id == currentBlockId }),
              idx > 0 else { return }
        let prevBlock = pageBlocks[idx - 1]
        deselectAll(except: prevBlock.id)
        interactionStates[prevBlock.id] = .editing
        activeBlockId = prevBlock.id
    }
}

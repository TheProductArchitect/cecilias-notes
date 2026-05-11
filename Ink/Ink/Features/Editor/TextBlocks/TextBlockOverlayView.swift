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
///   • Finger tap on empty space (text mode) → create block
///   • Finger tap inside idle block → select it
///   • Finger tap inside selected block → begin editing
///   • Finger drag on idle block → move it
///   • Finger drag on selected block outside handles → move it
struct TextBlockOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel

    @State private var activeBlockId: UUID?
    @State private var interactionStates: [UUID: TextBlockInteractionState] = [:]
    @State private var layouts: [UUID: TextBlockLayoutState] = [:]
    @State private var blockHeights: [UUID: CGFloat] = [:]

    // Move gesture tracking
    @State private var moveStartNorm: CGPoint?

    // Resize gesture tracking
    @State private var resizeStartRect: CGRect?

    // Link popover
    @State private var isShowingLinkPopover: Bool = false
    @State private var linkPopoverBlockId: UUID?
    @State private var linkPopoverRange: NSRange = NSRange()
    @State private var linkPopoverExistingURL: URL?

    // Keyboard offset — kept in sync with EditorViewModel
    @State private var keyboardOffset: CGFloat = 0

    var body: some View {
        let pageSize = viewModel.currentPage.pageSize.pointSize
        let blocks   = viewModel.currentPageTextBlocks

        ZStack(alignment: .topLeading) {
            // Transparent tap catcher for creating new blocks
            if viewModel.selectedTool.isTextMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        let norm = normalise(location, pageSize: pageSize)
                        createBlock(at: norm, pageSize: pageSize)
                    }
            }

            ForEach(blocks, id: \.id) { block in
                blockView(block: block, pageSize: pageSize)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .onChange(of: viewModel.currentPageIndex) { _, _ in syncLayouts() }
        .onAppear { syncLayouts() }
        // Link popover sheet
        .sheet(isPresented: $isShowingLinkPopover) {
            if let blockId = linkPopoverBlockId,
               let block = viewModel.currentPageTextBlocks.first(where: { $0.id == blockId }) {
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

        // Lecture-block routing. When the body's first line matches
        // `lecture:<uuid>` we render `LectureBlockView` instead of
        // the regular `TextBlockView`. The frame + position are
        // owned by the same TextBlock layout math so the block sits
        // exactly where the user dropped it — only the *contents*
        // of the rectangle change. No move / resize / selection
        // chrome for lecture blocks; the page is the scroll surface.
        if let lectureId = LectureBlockView.parseRecordId(fromBody: block.content) {
            LectureBlockView(recordId: lectureId, pageId: block.pageId)
                .frame(width: ptRect.width, alignment: .topLeading)
                .position(x: ptRect.midX, y: ptRect.minY + height / 2)
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
            Color.inkBackgroundElevated.opacity(0.92)
        } else if state == .selected {
            Color.inkAccentPrimary.opacity(0.04)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func blockBorder(state: TextBlockInteractionState) -> some View {
        if state == .editing {
            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                .strokeBorder(Color.inkAccentPrimary, lineWidth: 1)
        } else if state == .selected {
            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                .strokeBorder(Color.inkAccentPrimary.opacity(0.5), lineWidth: 1)
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

    private func createBlock(at normalizedOrigin: CGPoint, pageSize: CGSize) {
        deselectAll()
        let defaultWidth: Double  = 200.0 / pageSize.width
        let defaultHeight: Double =  60.0 / pageSize.height
        let rect = CGRect(
            x:      max(0, min(1 - defaultWidth,  Double(normalizedOrigin.x))),
            y:      max(0, min(1 - defaultHeight, Double(normalizedOrigin.y))),
            width:  defaultWidth,
            height: defaultHeight
        )
        guard let block = viewModel.createTextBlock(at: rect) else {
            // Silently ignore — block creation failures are non-critical
            return
        }
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
        for block in viewModel.currentPageTextBlocks {
            if layouts[block.id] == nil {
                layouts[block.id] = TextBlockLayoutState(from: block)
            }
        }
        // Remove stale entries
        let ids = Set(viewModel.currentPageTextBlocks.map(\.id))
        layouts.keys.filter { !ids.contains($0) }.forEach { layouts.removeValue(forKey: $0) }
        interactionStates.keys.filter { !ids.contains($0) }.forEach { interactionStates.removeValue(forKey: $0) }
        blockHeights.keys.filter { !ids.contains($0) }.forEach { blockHeights.removeValue(forKey: $0) }
    }

    // MARK: - Coordinate helpers

    private func normalise(_ point: CGPoint, pageSize: CGSize) -> CGPoint {
        CGPoint(x: point.x / pageSize.width, y: point.y / pageSize.height)
    }

    // MARK: - Focus navigation (Tab / Shift+Tab outside a list)

    /// Activates editing on the next text block by ascending zIndex. The list
    /// in `viewModel.currentPageTextBlocks` is already sorted by zIndex, so we
    /// simply walk forward from the current id.
    private func focusNextTextBlock(after currentBlockId: UUID) {
        let blocks = viewModel.currentPageTextBlocks
        guard let idx = blocks.firstIndex(where: { $0.id == currentBlockId }),
              idx + 1 < blocks.count else { return }
        let nextBlock = blocks[idx + 1]
        deselectAll(except: nextBlock.id)
        interactionStates[nextBlock.id] = .editing
        activeBlockId = nextBlock.id
    }

    /// Activates editing on the previous text block by descending zIndex.
    private func focusPreviousTextBlock(before currentBlockId: UUID) {
        let blocks = viewModel.currentPageTextBlocks
        guard let idx = blocks.firstIndex(where: { $0.id == currentBlockId }),
              idx > 0 else { return }
        let prevBlock = blocks[idx - 1]
        deselectAll(except: prevBlock.id)
        interactionStates[prevBlock.id] = .editing
        activeBlockId = prevBlock.id
    }
}

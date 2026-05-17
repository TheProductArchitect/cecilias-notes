/// ImageAttachmentsView.swift
/// Cecilia's Notes
///
/// Per-page render layer for image attachments. Sits between the
/// page background (template / PDF) and the PencilKit canvas so
/// handwriting always draws on top — the architectural rule is
/// non-negotiable.
///
/// Two interaction modes, gated by `viewModel.selectedTool`:
///   • Any tool ≠ `.image`  → images render but are inert. The
///     PencilKit canvas above receives all input.
///   • Tool == `.image`     → tap-to-select, drag-to-move,
///     pinch-to-resize (aspect-locked), corner-handle resize, tap
///     toolbar buttons for rotate / delete, drag the toolbar handle
///     to move the image. Tap on empty page background while a
///     selection is active clears the selection; tap on empty page
///     background with no selection opens the import picker centred
///     at the tap location.
///
/// Phase 4C: clean reimplementation of the selection surface.
/// Previous patches stacked gestures on the same view and let
/// `.onTapGesture` race with `.gesture(...)`, which left the visible
/// chrome stuck off-screen. This pass mounts each image in its own
/// container with the selection chrome (dashed border, floating
/// toolbar, four corner resize handles) drawn outside the image
/// bounds and hit-tested independently from the image body.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImageAttachmentsView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    /// Single placement primitive — base page size only, no effective
    /// height. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.A.
    let coordinateSpace: PageCoordinateSpace

    private var pageSize: CGSize { coordinateSpace.baseSize }

    /// Notification tick so the layer re-renders on
    /// `.mediaAttachmentsChanged`.
    @State private var refreshTick: Int = 0

    /// Currently-selected attachment id when the image tool is
    /// active. Cleared on tool switch.
    @State private var selectedId: UUID?

    /// Stable identity for this view instance, used by the diagnostic
    /// prints so we can correlate `BACKGROUND TAP HANDLER` /
    /// `IMAGE TAP REACHED` to a specific overlay when multiple are
    /// mounted simultaneously (the paginated canvas keeps neighbour
    /// pages alive for swipe transitions, so two `ImageAttachmentsView`
    /// instances can be on screen at once). `ObjectIdentifier(self)`
    /// is unavailable on SwiftUI structs — `@State` gives us
    /// per-instance stability instead.
    @State private var instanceID: UUID = UUID()

    var body: some View {
        let _ = refreshTick
        let records = MediaAttachmentStore.records(for: pageId)
        let imageMode = viewModel.selectedTool.isImageMode

        #if DEBUG
        // Phase-5-followup diagnostic 1 (image selection chrome).
        // Logs the full ZStack structure being built, including each
        // record's point-space frame, so we can verify on device
        // whether taps that escape into the background tap layer
        // actually fell inside or outside the image rect. Wrapped
        // in an IIFE so the `for` loop is legal inside the
        // ViewBuilder body.
        let _: () = {
            print("[ImageDiag] OVERLAY INSTANCE pageId=\(pageId) view-hash=\(instanceID.uuidString.prefix(8)) pageSize=\(pageSize)")
            print("[ImageDiag] body building: records.count=\(records.count) imageMode=\(imageMode) selectedTool=\(viewModel.selectedTool) pageSize=\(pageSize)")
            for (idx, record) in records.enumerated() {
                let frame = CGRect(
                    x: record.normalizedX      * pageSize.width,
                    y: record.normalizedY      * pageSize.height,
                    width:  record.normalizedWidth  * pageSize.width,
                    height: record.normalizedHeight * pageSize.height
                )
                print("[ImageDiag] record[\(idx)]: id=\(record.id) norm=(\(record.normalizedX),\(record.normalizedY)) \(record.normalizedWidth)x\(record.normalizedHeight) pointFrame=\(frame)")
            }
        }()
        #endif

        return ZStack(alignment: .topLeading) {
            // Background tap-anywhere surface for the image tool.
            // Drawn FIRST so it sits *behind* the image bodies — SwiftUI
            // hit-tests ZStack children top-to-bottom, so the per-image
            // `.onTapGesture` resolves before this full-page rect when
            // the touch lands inside an image.
            if imageMode {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: pageSize.width, height: pageSize.height)
                    .onTapGesture { location in
                        #if DEBUG
                        // Diagnostic 1 — log every background tap and
                        // whether it actually landed inside any
                        // image's rect. Distinguishes "background ate
                        // tap that should have hit image" from "user
                        // tapped empty space."
                        print("[ImageDiag] BACKGROUND TAP HANDLER fired on pageId=\(pageId) view-hash=\(instanceID.uuidString.prefix(8))")
                        print("[ImageDiag] BACKGROUND TAP: location=\(location) records.count=\(records.count) selectedId=\(String(describing: selectedId))")
                        for record in records {
                            let frame = CGRect(
                                x: record.normalizedX      * pageSize.width,
                                y: record.normalizedY      * pageSize.height,
                                width:  record.normalizedWidth  * pageSize.width,
                                height: record.normalizedHeight * pageSize.height
                            )
                            print("[ImageDiag]   record \(record.id) frame=\(frame) tap contains=\(frame.contains(location))")
                        }
                        #endif
                        if selectedId != nil {
                            selectedId = nil
                        } else {
                            presentPicker(
                                normalizedX: location.x / pageSize.width,
                                normalizedY: location.y / pageSize.height,
                                reason: "background tap on empty page area, no current selection"
                            )
                        }
                    }
            }

            ForEach(records) { record in
                attachmentContainer(for: record, imageMode: imageMode)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .onDrop(of: [.image], isTargeted: nil) { providers, location in
            handleDrop(providers: providers, at: location)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaAttachmentsChanged)
        ) { _ in refreshTick &+= 1 }
        .onChange(of: imageMode) { _, newValue in
            if !newValue { selectedId = nil }
        }
    }

    // MARK: - Per-image container

    /// Wraps a single record's view + its selection chrome in one
    /// position-anchored container. Selection chrome (dashed border,
    /// corner handles, floating toolbar) is drawn outside the image
    /// rect inside the same container, so it stays glued to the
    /// image during drag/resize transients without needing its own
    /// hit-test plumbing.
    @ViewBuilder
    private func attachmentContainer(
        for record: ImageRecord,
        imageMode: Bool
    ) -> some View {
        let isSelected = imageMode && selectedId == record.id
        let rect = pointRect(for: record)

        ImageAttachmentSlot(
            record:     record,
            isSelected: isSelected,
            imageMode:  imageMode,
            pageSize:   pageSize,
            pageId:     pageId,
            overlayViewHash: instanceID.uuidString.prefix(8).description,
            onSelect: {
                #if DEBUG
                print("[ImageInteract] tap on \(record.id) pageId=\(pageId) view-hash=\(instanceID.uuidString.prefix(8))")
                #endif
                selectedId = record.id
            },
            onDeselect: {
                if selectedId == record.id { selectedId = nil }
            },
            onDelete: {
                if selectedId == record.id { selectedId = nil }
                MediaAttachmentStore.softDelete(id: record.id, pageId: record.pageId)
            }
        )
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Geometry

    private func pointRect(for record: ImageRecord) -> CGRect {
        CGRect(
            x: record.normalizedX      * pageSize.width,
            y: record.normalizedY      * pageSize.height,
            width:  record.normalizedWidth  * pageSize.width,
            height: record.normalizedHeight * pageSize.height
        )
    }

    // MARK: - Picker signal

    private func presentPicker(
        normalizedX: Double,
        normalizedY: Double,
        reason: String
    ) {
        #if DEBUG
        print("[ImagePicker] presenting picker, reason=\(reason) pageId=\(pageId) view-hash=\(instanceID.uuidString.prefix(8)) at norm=(\(normalizedX),\(normalizedY))")
        let stack = Thread.callStackSymbols.prefix(6).joined(separator: "\n  ")
        print("[ImagePicker]   stack:\n  \(stack)")
        #endif
        NotificationCenter.default.post(
            name: .imageImportRequested,
            object: nil,
            userInfo: [
                ImageImportUserInfoKey.normalizedX: normalizedX,
                ImageImportUserInfoKey.normalizedY: normalizedY,
            ]
        )
    }

    // MARK: - Drag-and-drop

    private func handleDrop(
        providers: [NSItemProvider],
        at location: CGPoint
    ) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: UIImage.self) })
        else { return false }
        let normX = max(0, min(1, location.x / pageSize.width))
        let normY = max(0, min(1, location.y / pageSize.height))
        provider.loadObject(ofClass: UIImage.self) { object, _ in
            guard let image = object as? UIImage else { return }
            Task { @MainActor in
                viewModel.commitImportedImage(
                    image,
                    fileExtension: "jpg",
                    at: EditorViewModel.ImageImportRequest(
                        normalizedX: normX,
                        normalizedY: normY
                    )
                )
            }
        }
        return true
    }
}

// MARK: - ImageAttachmentSlot

/// One image + its selection chrome. Owns the transient drag /
/// resize / pinch deltas so the parent overlay's body only
/// re-evaluates on selection changes, not on every gesture tick.
private struct ImageAttachmentSlot: View {

    let record:     ImageRecord
    let isSelected: Bool
    let imageMode:  Bool
    let pageSize:   CGSize
    /// Diagnostic plumbing: identifies which overlay-instance this slot
    /// belongs to so the IMAGE TAP REACHED print correlates with the
    /// OVERLAY INSTANCE / BACKGROUND TAP HANDLER prints from its parent.
    let pageId: UUID
    let overlayViewHash: String
    let onSelect:   () -> Void
    let onDeselect: () -> Void
    let onDelete:   () -> Void

    /// Transient drag delta in points (committed to normalized on
    /// `.onEnded`). Applies to the image body and the toolbar's drag
    /// handle — both write here.
    @State private var dragOffset: CGSize = .zero
    /// Transient pinch scale (aspect-locked, around image centre).
    @State private var pinchScale: CGFloat = 1.0
    /// Transient corner-handle resize delta. The active corner
    /// captures the drag's start anchor; the opposite corner stays
    /// pinned in space while the dragged corner moves.
    @State private var resizeDelta: ResizeDelta? = nil

    private static let handleSize: CGFloat = 10
    private static let toolbarGap: CGFloat = 8
    private static let minNormalizedWidth: Double = 0.05

    private struct ResizeDelta: Equatable {
        var corner: Corner
        var translation: CGSize
    }
    private enum Corner: Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        // Compute the image's *displayed* rect inside the slot.
        // - Drag/pinch around centre.
        // - Corner-resize: anchor the opposite corner in place.
        let base = CGRect(x: 0, y: 0, width: rectWidth(), height: rectHeight())
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // The image body.
            ImageAttachmentLoader(
                url: MediaAttachmentStore.absoluteURL(for: record),
                displayWidth: displayed.width,
                displayHeight: displayed.height
            )
            .rotationEffect(.degrees(record.rotation))
            .frame(width: displayed.width, height: displayed.height)
            .contentShape(Rectangle())
            .position(x: displayed.midX, y: displayed.midY)
            .allowsHitTesting(imageMode)
            // Tap-to-select. `.simultaneousGesture` keeps the tap
            // from being eaten by the drag gesture below — both can
            // resolve on the same touch sequence.
            .simultaneousGesture(
                TapGesture().onEnded {
                    #if DEBUG
                    // Diagnostic 1 — every tap that actually reaches
                    // the image body fires this. Absence means the
                    // tap was eaten by a layer above (background,
                    // canvas, etc.) — pair with the BACKGROUND TAP
                    // contains=true/false output to localise.
                    print("[ImageDiag] IMAGE TAP REACHED record=\(record.id) on pageId=\(pageId) view-hash=\(overlayViewHash) imageMode=\(imageMode) isSelected=\(isSelected)")
                    #endif
                    guard imageMode else { return }
                    if !isSelected {
                        onSelect()
                        #if DEBUG
                        print("[ImageDiag]   → onSelect() called")
                        #endif
                    }
                }
            )
            // Drag the image body to move it. Active only when
            // selected so a stray finger drag on an unselected image
            // doesn't move it accidentally.
            .gesture(isSelected ? imageDragGesture : nil)
            // Pinch resize.
            .gesture(isSelected ? pinchResizeGesture : nil)

            if isSelected {
                // Dashed border + corner handles + floating toolbar.
                selectionChrome(imageRect: displayed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Displayed rect

    private func rectWidth()  -> CGFloat { record.normalizedWidth  * pageSize.width  }
    private func rectHeight() -> CGFloat { record.normalizedHeight * pageSize.height }

    /// Apply the transient gesture deltas to the base rect. The
    /// returned rect is in the slot's local coords (origin in the
    /// top-leading corner of the slot).
    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation)
        }
        let scale = pinchScale
        let w = base.width  * scale
        let h = base.height * scale
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Aspect-locked corner resize. The opposite corner is the
    /// anchor — it stays fixed in space; the dragged corner moves
    /// by the drag translation, and the size scales uniformly along
    /// the controlling diagonal so the image keeps its aspect ratio.
    private func resizedRect(
        base: CGRect,
        corner: Corner,
        translation: CGSize
    ) -> CGRect {
        let anchor: CGPoint
        let signX: CGFloat
        let signY: CGFloat
        switch corner {
        case .topLeft:     anchor = CGPoint(x: base.maxX, y: base.maxY); signX = -1; signY = -1
        case .topRight:    anchor = CGPoint(x: base.minX, y: base.maxY); signX =  1; signY = -1
        case .bottomLeft:  anchor = CGPoint(x: base.maxX, y: base.minY); signX = -1; signY =  1
        case .bottomRight: anchor = CGPoint(x: base.minX, y: base.minY); signX =  1; signY =  1
        }
        // New width / height implied by the dragged corner.
        let proposedW = max(1, base.width  + signX * translation.width)
        let proposedH = max(1, base.height + signY * translation.height)
        // Lock aspect: use whichever dimension changed more
        // (proportionally) as the controlling axis.
        let scaleW = proposedW / base.width
        let scaleH = proposedH / base.height
        let scale  = max(scaleW, scaleH)
        let w = base.width  * scale
        let h = base.height * scale
        let minW = CGFloat(Self.minNormalizedWidth) * pageSize.width
        let finalW = max(minW, w)
        let finalH = base.height * (finalW / base.width)
        // Pin the anchor — derive the dragged corner from the anchor.
        let x = anchor.x - (signX > 0 ? 0 : finalW)
        let y = anchor.y - (signY > 0 ? 0 : finalH)
        return CGRect(x: x, y: y, width: finalW, height: finalH)
    }

    // MARK: Selection chrome

    @ViewBuilder
    private func selectionChrome(imageRect: CGRect) -> some View {
        // Dashed border outline.
        Rectangle()
            .strokeBorder(
                Color.brandAccent,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: imageRect.width, height: imageRect.height)
            .position(x: imageRect.midX, y: imageRect.midY)
            .allowsHitTesting(false)

        // Corner resize handles.
        cornerHandle(.topLeft,     at: CGPoint(x: imageRect.minX, y: imageRect.minY))
        cornerHandle(.topRight,    at: CGPoint(x: imageRect.maxX, y: imageRect.minY))
        cornerHandle(.bottomLeft,  at: CGPoint(x: imageRect.minX, y: imageRect.maxY))
        cornerHandle(.bottomRight, at: CGPoint(x: imageRect.maxX, y: imageRect.maxY))

        // Floating toolbar — 8pt above the top edge.
        floatingToolbar()
            .position(
                x: imageRect.midX,
                y: max(14, imageRect.minY - Self.toolbarGap - 14)
            )
    }

    private func cornerHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(Color.brandAccent)
            .frame(width: Self.handleSize, height: Self.handleSize)
            // Hit area larger than the visible circle so the handle
            // is comfortable to grab with a fingertip.
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .gesture(resizeGesture(for: corner))
    }

    private func floatingToolbar() -> some View {
        HStack(spacing: 10) {
            // Drag handle — drag the toolbar to move the image.
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.inkTextPrimary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(imageDragGesture)

            Button {
                rotate()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.inkTextPrimary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.inkTextPrimary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: Gestures

    private var imageDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                var updated = record
                updated.normalizedX = clampNorm(record.normalizedX + dxNorm)
                updated.normalizedY = clampNorm(record.normalizedY + dyNorm)
                updated.updatedAt   = Date()
                MediaAttachmentStore.save(updated)
                dragOffset = .zero
            }
    }

    private var pinchResizeGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinchScale = max(0.2, min(5, value))
            }
            .onEnded { value in
                let clamped = max(0.2, min(5, value))
                var updated = record
                let newW = max(Self.minNormalizedWidth, record.normalizedWidth * Double(clamped))
                let newH = record.normalizedHeight * (newW / record.normalizedWidth)
                updated.normalizedWidth  = min(1, newW)
                updated.normalizedHeight = min(1, newH)
                updated.updatedAt        = Date()
                MediaAttachmentStore.save(updated)
                pinchScale = 1.0
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                let base = CGRect(x: 0, y: 0, width: rectWidth(), height: rectHeight())
                let new  = resizedRect(base: base, corner: corner, translation: value.translation)
                // The container's frame is anchored top-leading
                // inside the page — the displayed rect's origin
                // shift gets re-rendered as a normalized origin
                // shift on the record. Convert top-leading position
                // in the slot back to a normalized page position.
                var updated = record
                let originPageX = record.normalizedX * pageSize.width + new.minX
                let originPageY = record.normalizedY * pageSize.height + new.minY
                updated.normalizedX      = clampNorm(originPageX / pageSize.width)
                updated.normalizedY      = clampNorm(originPageY / pageSize.height)
                updated.normalizedWidth  = min(1, Double(new.width)  / Double(pageSize.width))
                updated.normalizedHeight = min(1, Double(new.height) / Double(pageSize.height))
                updated.updatedAt        = Date()
                MediaAttachmentStore.save(updated)
                resizeDelta = nil
            }
    }

    // MARK: Mutations

    private func rotate() {
        var updated = record
        let next = (record.rotation + 90).truncatingRemainder(dividingBy: 360)
        updated.rotation = next < 0 ? next + 360 : next
        updated.updatedAt = Date()
        MediaAttachmentStore.save(updated)
    }

    private func clampNorm(_ v: Double) -> Double { max(0, min(1, v)) }
}

// MARK: - Loader

/// Disk-backed image loader. Decodes off the main actor and caches
/// the resulting `UIImage` in memory once loaded.
private struct ImageAttachmentLoader: View {
    let url: URL
    let displayWidth: CGFloat
    let displayHeight: CGFloat

    @State private var image: UIImage?
    @State private var loadFailed: Bool = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if loadFailed {
                ZStack {
                    Rectangle().fill(Color.inkRecessiveQuinary)
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color.inkRecessiveTertiary)
                }
            } else {
                Rectangle().fill(Color.inkRecessiveQuinary)
            }
        }
        .task(id: url) { await loadIfNeeded() }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaAttachmentsChanged)
        ) { _ in
            guard image == nil else { return }
            Task { await loadIfNeeded() }
        }
    }

    private func loadIfNeeded() async {
        let path = url.path
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        await MainActor.run {
            if let loaded {
                self.image = loaded
                self.loadFailed = false
            } else {
                self.loadFailed = true
            }
        }
    }
}

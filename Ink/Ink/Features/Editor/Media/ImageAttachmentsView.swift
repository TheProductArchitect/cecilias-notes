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
///     pinch-to-resize (aspect-locked), tap rotate handle for 90°
///     step, tap delete handle for soft-delete. Tapping the empty
///     canvas dismisses the selection AND opens the import picker
///     centred at the tap location — same gesture covers both
///     "place a fresh image" and "deselect".

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ImageAttachmentsView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let pageSize: CGSize

    /// Notification tick so the layer re-renders on
    /// `.mediaAttachmentsChanged`. SwiftUI doesn't pick up
    /// notifications natively; this `@State` bump invalidates
    /// `records` on every store mutation.
    @State private var refreshTick: Int = 0

    /// Currently-selected attachment id when the image tool is
    /// active. Session-local per spec — selection doesn't persist
    /// when the user navigates away.
    @State private var selectedId: UUID?

    /// In-flight gestures — `nil` when no gesture is active.
    /// During a drag/pinch, the published normalised geometry is
    /// computed off the committed record + the gesture delta, then
    /// committed on `.onEnded` via `MediaAttachmentStore.save`.
    @State private var dragOffset: CGSize = .zero
    @State private var pinchScale: CGFloat = 1.0

    var body: some View {
        let _ = refreshTick
        let records = MediaAttachmentStore.records(for: pageId)
        let imageMode = viewModel.selectedTool.isImageMode

        ZStack(alignment: .topLeading) {
            // Tap-anywhere surface — only active in image mode.
            // Tap deselects any active selection; if the tap landed
            // on empty space (not on an image), it also seeds the
            // editor's "place at point" state so the import picker
            // can drop the new attachment there.
            if imageMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        if selectedId != nil {
                            selectedId = nil
                        } else {
                            presentPicker(
                                normalizedX: location.x / pageSize.width,
                                normalizedY: location.y / pageSize.height
                            )
                        }
                    }
            }

            ForEach(records) { record in
                attachment(for: record, imageMode: imageMode)
            }

            // Long-press surface. Always mounted at the back so the
            // gesture is available regardless of the active tool —
            // an "Insert Image" entry point that doesn't require
            // first switching to the image tool. The surface uses
            // `.allowsHitTesting(false)` on the existing tap layer
            // above by being placed underneath it; the
            // `LongPressGesture` here only resolves for sustained
            // finger touches, so Pencil drawing on the PKCanvasView
            // above is unaffected (it runs on a higher layer and
            // resolves first for any Pencil input).
            Color.clear
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.6) {
                    // Long-press goes straight to the import
                    // picker via the shared bridge. Presenting
                    // from `LibraryView` at the root level
                    // avoids the `.fullScreenCover → .sheet`
                    // collapse that previously closed the editor.
                    presentPicker(normalizedX: 0.5, normalizedY: 0.5)
                }
                .allowsHitTesting(!imageMode)
        }
        .frame(width: pageSize.width, height: pageSize.height)
        // Drag-and-drop entry. Active on every notebook regardless
        // of tool — `UTType.image` filters out non-image drag
        // payloads, the drop location is the centring anchor for
        // the new attachment. Accepts the first provider only —
        // multi-image drop is a future pass.
        .onDrop(of: [.image], isTargeted: nil) { providers, location in
            handleDrop(providers: providers, at: location)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .mediaAttachmentsChanged)
        ) { _ in refreshTick &+= 1 }
        // Selection survives only the lifetime of the image tool —
        // switching tools clears it so other surfaces aren't
        // visually confused by chrome that no longer affords.
        .onChange(of: imageMode) { _, newValue in
            if !newValue { selectedId = nil }
        }
    }

    // MARK: - Single attachment

    @ViewBuilder
    private func attachment(for record: MediaAttachmentRecord, imageMode: Bool) -> some View {
        let isSelected = imageMode && selectedId == record.id
        let baseRect = pointRect(for: record)
        // Apply transient gesture deltas — drag offsets the centre,
        // pinch scales the size around it.
        let centre = CGPoint(
            x: baseRect.midX + (isSelected ? dragOffset.width  : 0),
            y: baseRect.midY + (isSelected ? dragOffset.height : 0)
        )
        let scale: CGFloat = isSelected ? pinchScale : 1.0
        let displayWidth  = baseRect.width  * scale
        let displayHeight = baseRect.height * scale

        ImageAttachmentLoader(
            url: MediaAttachmentStore.absoluteURL(for: record),
            displayWidth: displayWidth,
            displayHeight: displayHeight
        )
        .rotationEffect(.degrees(record.rotationDegrees))
        .frame(width: displayWidth, height: displayHeight)
        .overlay(selectionChrome(record: record, isSelected: isSelected))
        .position(centre)
        // Hit-testing is disabled outside image mode so taps fall
        // through to the PencilKit canvas above (the canvas
        // already eats Pencil events; finger taps land on the
        // canvas's tap-to-place surfaces too).
        .allowsHitTesting(imageMode)
        .onTapGesture {
            guard imageMode else { return }
            selectedId = record.id
        }
        .gesture(imageMode && isSelected ? dragGesture(for: record) : nil)
        .gesture(imageMode && isSelected ? pinchGesture(for: record) : nil)
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private func selectionChrome(record: MediaAttachmentRecord, isSelected: Bool) -> some View {
        if isSelected {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(
                        Color.brandAccent,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
                // × delete handle, top-leading. Filled accent
                // circle so the affordance reads on bright images.
                Button {
                    delete(record)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.brandAccent))
                }
                .buttonStyle(.plain)
                .offset(x: -11, y: -11)

                // ⤴ rotate handle, top-trailing. Same circle, white
                // glyph. Cycles 0 → 90 → 180 → 270 → 0 per spec.
                Button {
                    rotate(record)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Color.brandAccent))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .topTrailing)
                .offset(x: 11, y: -11)
            }
        }
    }

    // MARK: - Geometry

    /// Convert a record's normalised bounds to point-space against
    /// the current page size.
    private func pointRect(for record: MediaAttachmentRecord) -> CGRect {
        CGRect(
            x: record.normalizedX      * pageSize.width,
            y: record.normalizedY      * pageSize.height,
            width:  record.normalizedWidth  * pageSize.width,
            height: record.normalizedHeight * pageSize.height
        )
    }

    // MARK: - Gestures

    private func dragGesture(for record: MediaAttachmentRecord) -> some Gesture {
        DragGesture()
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                // Commit by mutating the record's normalised origin
                // (top-left corner). Translation is in points, so
                // divide by the page dimensions to renormalise.
                var updated = record
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                updated.normalizedX = max(0, min(1, record.normalizedX + dxNorm))
                updated.normalizedY = max(0, min(1, record.normalizedY + dyNorm))
                updated.updatedAt   = Date()
                MediaAttachmentStore.save(updated)
                dragOffset = .zero
            }
    }

    private func pinchGesture(for record: MediaAttachmentRecord) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinchScale = max(0.2, min(5, value))
            }
            .onEnded { value in
                let clamped = max(0.2, min(5, value))
                // Aspect ratio is locked — scale both axes by the
                // same factor and re-clamp to [0,1].
                var updated = record
                updated.normalizedWidth  = min(1, record.normalizedWidth  * clamped)
                updated.normalizedHeight = min(1, record.normalizedHeight * clamped)
                updated.updatedAt        = Date()
                MediaAttachmentStore.save(updated)
                pinchScale = 1.0
            }
    }

    // MARK: - Mutations

    private func rotate(_ record: MediaAttachmentRecord) {
        var updated = record
        let next = (record.rotationDegrees + 90).truncatingRemainder(dividingBy: 360)
        updated.rotationDegrees = next < 0 ? next + 360 : next
        updated.updatedAt = Date()
        MediaAttachmentStore.save(updated)
    }

    private func delete(_ record: MediaAttachmentRecord) {
        MediaAttachmentStore.softDelete(id: record.id, pageId: record.pageId)
        if selectedId == record.id { selectedId = nil }
    }

    // MARK: - Picker bridge

    /// Trigger the import picker via `ImagePickerBridge`. The
    /// picker is presented from `LibraryView` at the root level —
    /// not from inside this overlay's hosting controller — so its
    /// dismiss/present cycle can't collapse the editor's
    /// `.fullScreenCover`. On a successful pick, the closure
    /// captures the normalised tap location and routes the image
    /// through `EditorViewModel.commitImportedImage`.
    private func presentPicker(normalizedX: Double, normalizedY: Double) {
        let vm = viewModel
        ImagePickerBridge.shared.present { image, ext in
            vm.commitImportedImage(
                image,
                fileExtension: ext,
                at: EditorViewModel.ImageImportRequest(
                    normalizedX: normalizedX,
                    normalizedY: normalizedY
                )
            )
        }
    }

    // MARK: - Drag-and-drop

    /// Resolve the first image-bearing provider into a `UIImage`,
    /// hand it to the view-model for the standard "write to disk +
    /// save record" flow. The drop location becomes the centring
    /// anchor — same as the tap-to-place path.
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

// MARK: - Loader

/// Disk-backed image loader. Decodes off the main actor and caches
/// the resulting `UIImage` in memory once loaded. Re-decodes if the
/// requested display size grows past 2× the previously-decoded
/// size — keeps memory bounded without re-decoding on every drag
/// frame.
private struct ImageAttachmentLoader: View {
    let url: URL
    let displayWidth: CGFloat
    let displayHeight: CGFloat

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                // Pale recessive placeholder while decoding. No
                // spinner — keeps the canvas quiet.
                Rectangle()
                    .fill(Color.inkRecessiveQuinary)
            }
        }
        .task(id: url) {
            await loadIfNeeded()
        }
    }

    private func loadIfNeeded() async {
        // Decode off the main actor — UIImage(contentsOfFile:) is
        // CPU-bound for large photos and blocks the canvas's
        // gesture pipeline if run inline.
        let path = url.path
        let loaded: UIImage? = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)
        }.value
        await MainActor.run { self.image = loaded }
    }
}

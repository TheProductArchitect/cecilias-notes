import SwiftUI
import UIKit

// MARK: - MediaAttachment Identifiable
extension MediaAttachment: Identifiable {}

// MARK: - MediaAttachmentOverlayView

/// Renders all MediaAttachments for the current page and handles selection,
/// move, scale, rotate, and context menu operations.
///
/// Render order: ascending zIndex (lowest = farthest back).
/// Images ARE selectable in any non-drawing tool mode; drawing tools pass through.
struct MediaAttachmentOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel

    @State private var interactionStates: [UUID: MediaAttachmentInteractionState] = [:]
    @State private var layouts: [UUID: MediaLayoutState] = [:]

    // Gesture tracking
    @State private var moveStartNorm: CGPoint?
    @State private var resizeStartRect: CGRect?
    @State private var rotationStart: Double?

    // Inline crop
    @State private var croppingAttachment: MediaAttachment?

    // Caption popover
    @State private var captionAttachment: MediaAttachment?
    @State private var captionText: String = ""
    @State private var isShowingCaption: Bool = false

    // Opacity popover
    @State private var opacityAttachment: MediaAttachment?
    @State private var opacityValue: Double = 1.0
    @State private var isShowingOpacity: Bool = false

    // Active transform feedback
    @State private var activeRotation: Double?    // current angle in radians for label
    @State private var activeSize: CGSize?        // current size in pts for label
    @State private var activeTransformId: UUID?

    // Snap guide state
    @State private var showHorizontalGuide: Bool = false
    @State private var showVerticalGuide: Bool   = false

    var body: some View {
        let pageSize = viewModel.currentPage.pageSize.pointSize
        let attachments = viewModel.currentPageAttachments

        ZStack(alignment: .topLeading) {
            // Transparent tap catcher — deselects all when tapping empty space.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { deselectAll() }

            // Snap guides
            snapGuides(pageSize: pageSize)

            ForEach(attachments.sorted(by: { $0.zIndex < $1.zIndex }), id: \.id) { att in
                attachmentView(att, pageSize: pageSize)
            }

            // Transform feedback labels
            transformFeedbackLabels()
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .onAppear { syncLayouts() }
        .onReceive(viewModel.$currentPage) { _ in syncLayouts() }
        // Crop sheet
        .fullScreenCover(item: $croppingAttachment) { att in
            InlineCropView(attachment: att) { croppedJpeg, newWidth, newHeight in
                viewModel.replaceAttachmentImage(att, jpegData: croppedJpeg,
                                                  originalWidth: newWidth,
                                                  originalHeight: newHeight)
                viewModel.refreshCurrentPageAttachments()
            }
        }
        // Caption popover
        .popover(isPresented: $isShowingCaption) {
            captionPopover()
        }
        // Opacity popover
        .popover(isPresented: $isShowingOpacity) {
            opacityPopover()
        }
    }

    // MARK: - Single attachment

    @ViewBuilder
    private func attachmentView(_ att: MediaAttachment, pageSize: CGSize) -> some View {
        let layout = layouts[att.id] ?? MediaLayoutState(from: att)
        let state  = interactionStates[att.id] ?? .idle
        let ptRect = layout.pointRect(pageSize: pageSize)

        Group {
            MediaAttachmentView(
                attachment: att,
                frameWidth: ptRect.width,
                opacity: layout.opacity
            )
        }
        .frame(width: ptRect.width, height: ptRect.height)
        .clipShape(Rectangle())
        .overlay { if state != .idle { selectionBorder(state: state) } }
        .rotationEffect(.radians(layout.rotation))
        .position(x: ptRect.midX, y: ptRect.midY)
        .gesture(moveGesture(att: att, pageSize: pageSize))
        .onTapGesture { handleTap(on: att) }
        .contextMenu { contextMenu(for: att, pageSize: pageSize) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.mediaLabel(caption: att.caption))
        .accessibilityHint(A11y.mediaHint)
        .accessibilityAddTraits(.isButton)

        // Selection chrome: handles + rotation handle
        if state == .selected || state == .transforming {
            transformHandles(att: att, layout: layout, ptRect: ptRect, pageSize: pageSize)
        }

        // Caption below image
        if let caption = att.caption, !caption.isEmpty, state != .transforming {
            Text(caption)
                .font(.inkCaption)
                .foregroundColor(.inkTextSecondary)
                .position(x: ptRect.midX, y: ptRect.maxY + 14)
        }
    }

    // MARK: - Selection border

    @ViewBuilder
    private func selectionBorder(state: MediaAttachmentInteractionState) -> some View {
        if state == .transforming {
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(
                    Color.inkAccentPrimary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
        } else {
            RoundedRectangle(cornerRadius: 0)
                .strokeBorder(Color.inkAccentPrimary, lineWidth: 1.5)
        }
    }

    // MARK: - Transform handles

    @ViewBuilder
    private func transformHandles(att: MediaAttachment, layout: MediaLayoutState,
                                   ptRect: CGRect, pageSize: CGSize) -> some View {
        let handles = MediaTransformHandle.allCases

        ForEach(handles, id: \.self) { handle in
            handleCircle(for: handle, att: att, layout: layout,
                         ptRect: ptRect, pageSize: pageSize)
        }
    }

    @ViewBuilder
    private func handleCircle(for handle: MediaTransformHandle, att: MediaAttachment,
                               layout: MediaLayoutState, ptRect: CGRect, pageSize: CGSize) -> some View {
        let handleSize: CGFloat = handle == .rotation ? 20 : 10
        let pos = handlePosition(handle: handle, ptRect: ptRect)

        Group {
            if handle == .rotation {
                // Rotation handle: accent-filled circle with curved arrow
                Circle()
                    .fill(Color.inkAccentPrimary)
                    .frame(width: handleSize, height: handleSize)
                    .overlay(
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    )
            } else {
                Circle()
                    .fill(Color.inkBackgroundElevated)
                    .overlay(Circle().strokeBorder(Color.inkAccentPrimary, lineWidth: 1.5))
                    .frame(width: handleSize, height: handleSize)
            }
        }
        .position(pos)
        .gesture(handleDrag(handle: handle, att: att, layout: layout,
                            ptRect: ptRect, pageSize: pageSize))
    }

    private func handlePosition(handle: MediaTransformHandle, ptRect: CGRect) -> CGPoint {
        let anchor = handle.anchor
        return CGPoint(
            x: ptRect.origin.x + anchor.x * ptRect.width,
            y: ptRect.origin.y + anchor.y * ptRect.height
        )
    }

    // MARK: - Handle drag gesture

    private func handleDrag(handle: MediaTransformHandle, att: MediaAttachment,
                             layout: MediaLayoutState, ptRect: CGRect,
                             pageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                interactionStates[att.id] = .transforming
                activeTransformId = att.id

                if handle == .rotation {
                    // Compute angle from block centre to drag point
                    let centre = CGPoint(x: ptRect.midX, y: ptRect.midY)
                    let dx = value.location.x - centre.x
                    let dy = value.location.y - centre.y
                    var angle = atan2(dy, dx) + .pi / 2
                    if rotationStart == nil { rotationStart = layout.rotation - angle }
                    angle = (rotationStart ?? 0) + angle
                    var l = layouts[att.id] ?? layout
                    l.rotation = angle
                    layouts[att.id] = l
                    activeRotation  = angle
                } else {
                    // Scale
                    if resizeStartRect == nil { resizeStartRect = layout.normalizedRect }
                    guard let start = resizeStartRect else { return }
                    let dx = value.translation.width  / pageSize.width
                    let dy = value.translation.height / pageSize.height
                    let minDim: CGFloat = 48 / max(pageSize.width, pageSize.height)

                    var newRect = start
                    let proportional = handle.isCorner   // Alt key isn't easily detectable on iPad; corner = proportional
                    let aspect = start.width > 0 ? start.height / start.width : 1

                    if handle.movesLeft {
                        newRect.origin.x  = min(start.maxX - minDim, start.origin.x + dx)
                        newRect.size.width = start.maxX - newRect.origin.x
                    }
                    if handle.movesRight  { newRect.size.width  = max(minDim, start.width  + dx) }
                    if handle.movesTop {
                        newRect.origin.y  = min(start.maxY - minDim, start.origin.y + dy)
                        newRect.size.height = start.maxY - newRect.origin.y
                    }
                    if handle.movesBottom { newRect.size.height = max(minDim, start.height + dy) }

                    if proportional {
                        // Lock aspect ratio: use whichever dimension changed more
                        let wDelta = abs(newRect.width  - start.width)
                        let hDelta = abs(newRect.height - start.height)
                        if wDelta > hDelta { newRect.size.height = newRect.width  * aspect }
                        else               { newRect.size.width  = newRect.height / aspect }
                    }

                    var l = layouts[att.id] ?? layout
                    l.normalizedRect = newRect
                    layouts[att.id]  = l

                    let ptW = newRect.width  * pageSize.width
                    let ptH = newRect.height * pageSize.height
                    activeSize = CGSize(width: ptW, height: ptH)

                    // Snap guides
                    let midX = (newRect.origin.x + newRect.width  / 2) * pageSize.width
                    let midY = (newRect.origin.y + newRect.height / 2) * pageSize.height
                    showVerticalGuide   = abs(midX - pageSize.width  / 2) < 4
                    showHorizontalGuide = abs(midY - pageSize.height / 2) < 4
                }
            }
            .onEnded { _ in
                rotationStart   = nil
                resizeStartRect = nil
                activeRotation  = nil
                activeSize      = nil
                activeTransformId = nil
                showVerticalGuide   = false
                showHorizontalGuide = false
                commitLayout(att: att)
                interactionStates[att.id] = .selected
            }
    }

    // MARK: - Move gesture

    private func moveGesture(att: MediaAttachment, pageSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                guard interactionStates[att.id] != nil else { return }
                if moveStartNorm == nil {
                    let l = layouts[att.id] ?? MediaLayoutState(from: att)
                    moveStartNorm = l.normalizedRect.origin
                }
                guard let start = moveStartNorm else { return }
                let dx = value.translation.width  / pageSize.width
                let dy = value.translation.height / pageSize.height
                var l = layouts[att.id] ?? MediaLayoutState(from: att)
                l.normalizedRect.origin = CGPoint(
                    x: max(0, min(1 - l.normalizedRect.width,  start.x + dx)),
                    y: max(0, min(1 - l.normalizedRect.height, start.y + dy))
                )
                layouts[att.id] = l
                interactionStates[att.id] = .transforming
                activeTransformId = att.id

                // Snap guides
                let midX = (l.normalizedRect.origin.x + l.normalizedRect.width  / 2) * pageSize.width
                let midY = (l.normalizedRect.origin.y + l.normalizedRect.height / 2) * pageSize.height
                showVerticalGuide   = abs(midX - pageSize.width  / 2) < 4
                showHorizontalGuide = abs(midY - pageSize.height / 2) < 4
            }
            .onEnded { _ in
                moveStartNorm = nil
                showVerticalGuide = false; showHorizontalGuide = false
                activeTransformId = nil
                commitLayout(att: att)
                interactionStates[att.id] = .selected
            }
    }

    // MARK: - Tap

    private func handleTap(on att: MediaAttachment) {
        guard viewModel.selectedTool.isMediaInteractive else { return }
        deselectAll(except: att.id)
        let current = interactionStates[att.id] ?? .idle
        interactionStates[att.id] = current == .idle ? .selected : .selected
    }

    private func deselectAll(except id: UUID? = nil) {
        for key in interactionStates.keys where key != id {
            interactionStates[key] = .idle
        }
    }

    // MARK: - Snap guides

    @ViewBuilder
    private func snapGuides(pageSize: CGSize) -> some View {
        if showHorizontalGuide {
            Rectangle()
                .fill(Color.inkAccentPrimary.opacity(0.4))
                .frame(width: pageSize.width, height: 1)
                .position(x: pageSize.width / 2, y: pageSize.height / 2)
        }
        if showVerticalGuide {
            Rectangle()
                .fill(Color.inkAccentPrimary.opacity(0.4))
                .frame(width: 1, height: pageSize.height)
                .position(x: pageSize.width / 2, y: pageSize.height / 2)
        }
    }

    // MARK: - Transform feedback labels

    @ViewBuilder
    private func transformFeedbackLabels() -> some View {
        if let angle = activeRotation, let id = activeTransformId,
           let layout = layouts[id] {
            let degrees = Int(round(angle * 180 / .pi))
            let ptRect  = layout.pointRect(pageSize: viewModel.currentPage.pageSize.pointSize)
            Text("\(degrees)°")
                .font(.inkCaption)
                .foregroundColor(.inkTextPrimary)
                .padding(.horizontal, Ink.Spacing.xs)
                .padding(.vertical, 2)
                .background(Color.inkBackgroundElevated.opacity(0.9))
                .clipShape(Capsule())
                .position(x: ptRect.midX, y: ptRect.maxY + 24)
        }

        if let size = activeSize, let id = activeTransformId,
           let layout = layouts[id] {
            let ptRect = layout.pointRect(pageSize: viewModel.currentPage.pageSize.pointSize)
            Text("\(Int(size.width)) × \(Int(size.height)) pt")
                .font(.inkCaption)
                .foregroundColor(.inkTextPrimary)
                .padding(.horizontal, Ink.Spacing.xs)
                .padding(.vertical, 2)
                .background(Color.inkBackgroundElevated.opacity(0.9))
                .clipShape(Capsule())
                .position(x: ptRect.midX, y: ptRect.maxY + 24)
        }
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for att: MediaAttachment, pageSize: CGSize) -> some View {
        let layout = layouts[att.id] ?? MediaLayoutState(from: att)

        Button { fitToWidth(att, pageSize: pageSize) } label: {
            Label("Fit to Width", systemImage: "arrow.left.and.right")
        }
        Button { fitToHeight(att, pageSize: pageSize) } label: {
            Label("Fit to Height", systemImage: "arrow.up.and.down")
        }
        Button { actualSize(att, pageSize: pageSize) } label: {
            Label("Actual Size", systemImage: "1.square")
        }

        Divider()

        Button { croppingAttachment = att } label: {
            Label("Crop…", systemImage: "crop")
        }

        Button {
            captionAttachment = att
            captionText       = att.caption ?? ""
            isShowingCaption  = true
        } label: {
            Label("Caption…", systemImage: "text.below.photo")
        }

        Button {
            opacityAttachment = att
            opacityValue      = att.opacity
            isShowingOpacity  = true
        } label: {
            Label("Opacity…", systemImage: "slider.horizontal.3")
        }

        Divider()

        Button { adjustZIndex(att, delta: -1) } label: {
            Label("Send Backward", systemImage: "square.2.layers.3d.top.filled")
        }
        Button { adjustZIndex(att, delta: 1) } label: {
            Label("Bring Forward", systemImage: "square.2.layers.3d.bottom.filled")
        }
        Button { sendToBack(att) } label: {
            Label("Send to Back", systemImage: "arrow.down.to.line")
        }
        Button { bringToFront(att) } label: {
            Label("Bring to Front", systemImage: "arrow.up.to.line")
        }

        Divider()

        Button {
            if let img = UIImage(contentsOfFile: viewModel.mediaURL(for: att).path) {
                UIPasteboard.general.image = img
            }
        } label: {
            Label("Copy Image", systemImage: "doc.on.clipboard")
        }

        Button(role: .destructive) {
            deleteAttachment(att)
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: - Context menu actions

    private func fitToWidth(_ att: MediaAttachment, pageSize: CGSize) {
        var l = layouts[att.id] ?? MediaLayoutState(from: att)
        let aspect = att.originalHeight > 0
            ? Double(att.originalHeight) / Double(att.originalWidth)
            : 1.0
        l.normalizedRect.origin.x = 0
        l.normalizedRect.size.width  = 1.0
        l.normalizedRect.size.height = min(1.0, aspect)
        layouts[att.id] = l
        commitLayout(att: att)
    }

    private func fitToHeight(_ att: MediaAttachment, pageSize: CGSize) {
        var l = layouts[att.id] ?? MediaLayoutState(from: att)
        let aspect = att.originalWidth > 0
            ? Double(att.originalWidth) / Double(att.originalHeight)
            : 1.0
        l.normalizedRect.origin.y = 0
        l.normalizedRect.size.height = 1.0
        l.normalizedRect.size.width  = min(1.0, aspect)
        layouts[att.id] = l
        commitLayout(att: att)
    }

    private func actualSize(_ att: MediaAttachment, pageSize: CGSize) {
        var l = layouts[att.id] ?? MediaLayoutState(from: att)
        let w = min(Double(att.originalWidth),  Double(pageSize.width))
        let h = min(Double(att.originalHeight), Double(pageSize.height))
        l.normalizedRect.size = CGSize(width:  w / pageSize.width,
                                       height: h / pageSize.height)
        layouts[att.id] = l
        commitLayout(att: att)
    }

    private func adjustZIndex(_ att: MediaAttachment, delta: Int) {
        let all = viewModel.currentPageAttachments.sorted { $0.zIndex < $1.zIndex }
        guard let idx = all.firstIndex(where: { $0.id == att.id }) else { return }
        let swapIdx = idx + delta
        guard swapIdx >= 0, swapIdx < all.count else { return }
        let other = all[swapIdx]
        let myZ   = att.zIndex
        let otherZ = other.zIndex
        viewModel.updateAttachmentZIndex(att,   zIndex: otherZ)
        viewModel.updateAttachmentZIndex(other, zIndex: myZ)
    }

    private func sendToBack(_ att: MediaAttachment) {
        let minZ = viewModel.currentPageAttachments.map(\.zIndex).min() ?? 0
        viewModel.updateAttachmentZIndex(att, zIndex: minZ - 1)
    }

    private func bringToFront(_ att: MediaAttachment) {
        let maxZ = viewModel.currentPageAttachments.map(\.zIndex).max() ?? 0
        viewModel.updateAttachmentZIndex(att, zIndex: maxZ + 1)
    }

    private func deleteAttachment(_ att: MediaAttachment) {
        // Register undo before deletion
        viewModel.registerAttachmentUndo(att)
        viewModel.deleteAttachment(att)
        layouts.removeValue(forKey: att.id)
        interactionStates.removeValue(forKey: att.id)
    }

    // MARK: - Commit

    private func commitLayout(att: MediaAttachment) {
        guard let layout = layouts[att.id] else { return }
        viewModel.updateAttachment(att,
                                    rect:     layout.normalizedRect,
                                    rotation: layout.rotation)
    }

    // MARK: - Popovers

    @ViewBuilder
    private func captionPopover() -> some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            Text("Caption")
                .font(.inkSubhead)
                .foregroundColor(.inkTextPrimary)
            TextField("Add a caption…", text: $captionText)
                .font(.inkBody)
                .textFieldStyle(.plain)
                .padding(Ink.Spacing.sm)
                .background(Color.inkBackgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
            HStack {
                Spacer()
                Button("Done") {
                    if let att = captionAttachment {
                        viewModel.updateAttachment(att, caption: captionText)
                        viewModel.refreshCurrentPageAttachments()
                    }
                    isShowingCaption = false
                }
                .font(.inkBody)
                .foregroundColor(.inkAccentPrimary)
            }
        }
        .padding(Ink.Spacing.md)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func opacityPopover() -> some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            HStack {
                Text("Opacity")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                Spacer()
                Text("\(Int(opacityValue * 100))%")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextSecondary)
                    .monospacedDigit()
            }
            Slider(value: $opacityValue, in: 0.2...1.0, step: 0.05)
                .tint(.inkAccentPrimary)
                .onChange(of: opacityValue) { _, v in
                    if let att = opacityAttachment {
                        var l = layouts[att.id] ?? MediaLayoutState(from: att)
                        l.opacity = v
                        layouts[att.id] = l
                    }
                }
            Button("Done") {
                if let att = opacityAttachment {
                    viewModel.updateAttachment(att, opacity: opacityValue)
                    viewModel.refreshCurrentPageAttachments()
                }
                isShowingOpacity = false
            }
            .font(.inkBody)
            .foregroundColor(.inkAccentPrimary)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(Ink.Spacing.md)
        .frame(width: 240)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: - Sync

    private func syncLayouts() {
        for att in viewModel.currentPageAttachments {
            if layouts[att.id] == nil {
                layouts[att.id] = MediaLayoutState(from: att)
            }
        }
        let ids = Set(viewModel.currentPageAttachments.map(\.id))
        layouts.keys.filter { !ids.contains($0) }.forEach { layouts.removeValue(forKey: $0) }
        interactionStates.keys.filter { !ids.contains($0) }.forEach { interactionStates.removeValue(forKey: $0) }
    }
}

import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement` of kind `.image` inside its
/// normalised page bounds. Second PageElement-backed view (after
/// `TextElementView`); follows the same template — element +
/// bindable content + page-size projection + selection chrome
/// composited over the renderable.
///
/// Selection chrome (mirrors the visual treatment of the legacy
/// `ImageAttachmentSlot` so the user perceives no regression):
///   • Dashed accent border (1.5pt, dash [4, 3]).
///   • Four corner handles (10pt accent circles, hit-expanded
///     -8pt) drive aspect-locked resize via opposite-corner
///     anchoring.
///   • Floating toolbar above the image: drag-handle (move),
///     90° rotate, delete.
///   • Pinch-to-resize on the image body (aspect-locked, around
///     centre).
///   • Drag on the image body to move (when selected).
struct ImageElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: ImageContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    /// Invoked when the user taps the floating toolbar's trash icon.
    /// The overlay clears `selectedId` and soft-deletes via
    /// `element.deletedAt = Date()` — letting the parent own the
    /// fetch refresh keeps SwiftData mutations in one place.
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var modifierKeys = ModifierKeyObserver.shared
    /// True while the full-screen crop sheet is presented.
    @State private var isCropping: Bool = false

    // Transient gesture deltas — kept local so a drag/resize tick
    // doesn't write to SwiftData every frame; commits land on
    // `.onEnded`.
    @State private var dragOffset: CGSize = .zero
    @State private var pinchScale: CGFloat = 1.0
    @State private var resizeDelta: ResizeDelta? = nil
    /// Live rotation (radians) while dragging the rotation handle; nil
    /// when idle. Commit lands on `.onEnded`, like the other gestures.
    @State private var liveRotation: Double? = nil
    @State private var rotationBase: Double = 0
    private static let handleSize: CGFloat = 10
    private static let toolbarGap: CGFloat = 8
    private static let rotationSpace = "imageRotationPageSpace"
    private static let minNormalizedWidth: Double = 0.05

    private struct ResizeDelta: Equatable {
        var corner: Corner
        var translation: CGSize
    }
    private enum Corner: Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        // Snap the persisted normalizedHeight to the image's actual
        // aspect ratio on first render. Legacy insert paths sometimes
        // wrote a height that didn't match the image's intrinsic
        // shape — the selection chrome ended up boxier than the
        // visible image, with white padding above/below as the image
        // letterboxed inside via `.aspectRatio(.fit)`. The fix
        // persists once and lets the box hug the image afterwards.
        let _ = snapHeightToIntrinsicAspectIfNeeded()
        let base = CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: element.normalizedWidth * pageSize.width,
            height: element.normalizedHeight * pageSize.height
        )
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // Order is load-bearing — gestures MUST sit before
            // `.position(...)`. After Step 7.2's sticky-gesture
            // post-mortem: `.position` wraps the modified view in
            // a parent-sized container; any gesture attached
            // after `.position` ends up bound to that container
            // instead of the framed contentShape, which on iPad
            // OS 26 causes the gesture to never fire even when
            // the hit area is correct. Apply the canonical
            // template established by `StickyNoteElementView`:
            //   frame → overlays/effects → contentShape →
            //   gestures → position.
            ImageDataView(content: content)
                // Rotation around the image's OWN centre (applied
                // before `.frame`/`.position`): the committed angle or
                // the live handle drag (`liveRotation`), PLUS any live
                // lasso-rotation delta for this element.
                .elementRotation(elementId: element.id, radians: liveRotation ?? element.rotation)
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        if !isSelected { isSelected = true }
                    }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        // Select on long-press too. A press held past
                        // the long-press threshold does NOT also fire
                        // the simultaneous `TapGesture`, so without
                        // this a slow press never selects the image —
                        // and the drag gesture (gated on `isSelected`)
                        // never attaches, so the image can't be moved.
                        if !isSelected { isSelected = true }
                    }
                )
                .gesture(isSelected ? imageDragGesture : nil)
                .gesture(isSelected ? pinchResizeGesture : nil)
                .position(x: displayed.midX, y: displayed.midY)

            if isSelected {
                selectionChrome(imageRect: displayed)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .coordinateSpace(name: Self.rotationSpace)
        .onChange(of: isSelected) { oldValue, newValue in
        }
        .fullScreenCover(isPresented: $isCropping) {
            ImageCropSheet(
                content: content,
                onDone:   { isCropping = false },
                onCancel: { isCropping = false }
            )
        }
    }

    /// Lazy aspect-ratio reconciliation. When the persisted box
    /// height doesn't match the image's intrinsic pixel aspect
    /// (`originalPixelHeight / originalPixelWidth`) within a small
    /// tolerance, snap the height to the correct value and save.
    /// One-shot per element: subsequent renders observe the corrected
    /// data and the predicate goes false.
    ///
    /// Pre-requisites — we need pixel dimensions on the content row.
    /// Older inserts didn't populate them; for those the function is
    /// a no-op (returns false) and the box keeps whatever aspect was
    /// stored. New inserts always set them, so any image touched
    /// after this commit gets the corrected box once.
    @discardableResult
    private func snapHeightToIntrinsicAspectIfNeeded() -> Bool {
        guard content.originalPixelWidth > 0,
              content.originalPixelHeight > 0,
              element.normalizedWidth > 0
        else { return false }
        let imageAspect = Double(content.originalPixelHeight) / Double(content.originalPixelWidth)
        let pageAspect  = Double(pageSize.height) / Double(pageSize.width)
        // Convert image aspect (height/width in pixels) to normalised
        // space — page height in normalised units is 1, page width is
        // 1, but pixel widths differ. We want
        //   displayedH = displayedW * imageAspect
        // where displayed* are in pt. Translating to normalised:
        //   normH * pageH = (normW * pageW) * imageAspect
        //   normH = normW * imageAspect / pageAspect
        let correctNormH = element.normalizedWidth * imageAspect / pageAspect
        // Tolerance: 1.5% — visible padding above ~2% is what the
        // bug report described.
        guard abs(correctNormH - element.normalizedHeight) > 0.015 else { return false }
        let clamped = max(0.01, min(1, correctNormH))
        // Defer the mutation a runloop tick — writing to SwiftData
        // from inside a SwiftUI body evaluation is exactly the
        // "Publishing changes from within view updates" trap.
        let target = clamped
        DispatchQueue.main.async {
            element.normalizedHeight = target
            element.updatedAt = Date()
            try? StorageService.shared.context.save()
        }
        return true
    }

    // MARK: - Displayed rect (gesture-deltas applied to base)

    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation,
                               freeAxis: modifierKeys.isShiftHeld)
        }
        let scale = pinchScale
        let w = base.width  * scale
        let h = base.height * scale
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Corner resize. The opposite corner stays pinned; the dragged
    /// corner moves by the drag translation.
    ///
    /// - `freeAxis` false (default): aspect-locked — size scales
    ///   uniformly along the controlling diagonal (Shift NOT held).
    /// - `freeAxis` true: width and height scale independently
    ///   (Shift held on a hardware keyboard).
    private func resizedRect(
        base: CGRect,
        corner: Corner,
        translation: CGSize,
        freeAxis: Bool = false
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
        let minW = CGFloat(Self.minNormalizedWidth) * pageSize.width
        if freeAxis {
            let finalW = max(minW, base.width  + signX * translation.width)
            let finalH = max(minW, base.height + signY * translation.height)
            let x = anchor.x - (signX > 0 ? 0 : finalW)
            let y = anchor.y - (signY > 0 ? 0 : finalH)
            return CGRect(x: x, y: y, width: finalW, height: finalH)
        }
        let proposedW = max(1, base.width  + signX * translation.width)
        let proposedH = max(1, base.height + signY * translation.height)
        let scale  = max(proposedW / base.width, proposedH / base.height)
        let finalW = max(minW, base.width * scale)
        let finalH = base.height * (finalW / base.width)
        let x = anchor.x - (signX > 0 ? 0 : finalW)
        let y = anchor.y - (signY > 0 ? 0 : finalH)
        return CGRect(x: x, y: y, width: finalW, height: finalH)
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private func selectionChrome(imageRect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(
                theme.accent,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: imageRect.width, height: imageRect.height)
            .position(x: imageRect.midX, y: imageRect.midY)
            .allowsHitTesting(false)

        cornerHandle(.topLeft,     at: CGPoint(x: imageRect.minX, y: imageRect.minY))
        cornerHandle(.topRight,    at: CGPoint(x: imageRect.maxX, y: imageRect.minY))
        cornerHandle(.bottomLeft,  at: CGPoint(x: imageRect.minX, y: imageRect.maxY))
        cornerHandle(.bottomRight, at: CGPoint(x: imageRect.maxX, y: imageRect.maxY))

        rotationHandle(imageRect: imageRect)

        floatingToolbar()
            .position(
                x: imageRect.midX,
                y: max(14, imageRect.minY - Self.toolbarGap - 14)
            )
    }

    /// Free-angle rotation knob below the image, dragged around the
    /// image centre. Complements the toolbar's 90° button (the
    /// "rotate to an angle" affordance the image chrome was missing).
    /// The centre and the touch are resolved in the same page-named
    /// coordinate space so the angle math is translation-invariant.
    @ViewBuilder
    private func rotationHandle(imageRect: CGRect) -> some View {
        let center = CGPoint(x: imageRect.midX, y: imageRect.midY)
        let stemBottom = CGPoint(x: imageRect.midX, y: imageRect.maxY)
        let knob = CGPoint(x: imageRect.midX, y: imageRect.maxY + 26)

        Path { p in
            p.move(to: stemBottom)
            p.addLine(to: knob)
        }
        .stroke(theme.accent, lineWidth: 1)
        .allowsHitTesting(false)

        Image(systemName: "arrow.clockwise")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: Self.handleSize + 6, height: Self.handleSize + 6)
            .background(Circle().fill(theme.accent))
            .contentShape(Circle().inset(by: -10))
            .position(knob)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.rotationSpace))
                    .onChanged { value in
                        if liveRotation == nil { rotationBase = element.rotation }
                        let delta = Self.angle(from: value.startLocation, to: value.location, around: center)
                        liveRotation = rotationBase + delta
                    }
                    .onEnded { value in
                        // A tap-without-drag can deliver `.onEnded`
                        // without any `.onChanged` tick — `rotationBase`
                        // would then be stale from the PREVIOUS gesture
                        // and the commit would snap the image to an old
                        // angle. Lazy-init here mirrors `.onChanged`.
                        if liveRotation == nil { rotationBase = element.rotation }
                        let delta = Self.angle(from: value.startLocation, to: value.location, around: center)
                        let final = rotationBase + delta
                        liveRotation = nil
                        LassoTransformUndo.withUndo(
                            elementId: element.id, actionName: "Rotate Image"
                        ) {
                            let twoPi = 2 * Double.pi
                            element.rotation = final.truncatingRemainder(dividingBy: twoPi)
                            element.updatedAt = Date()
                        }
                    }
            )
    }

    /// Signed angle (radians) swept from `start` to `end` about `center`.
    private static func angle(from start: CGPoint, to end: CGPoint, around center: CGPoint) -> Double {
        let a0 = atan2(Double(start.y - center.y), Double(start.x - center.x))
        let a1 = atan2(Double(end.y - center.y), Double(end.x - center.x))
        return a1 - a0
    }

    private func cornerHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(theme.accent)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .gesture(resizeGesture(for: corner))
    }

    private func floatingToolbar() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.foreground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(imageDragGesture)

            Button {
                rotate90()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                PageElementOrdering.apply(.toFront, to: element,
                                          context: StorageService.shared.context)
            } label: {
                Image(systemName: "square.3.layers.3d.top.filled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Bring to Front")

            Button {
                PageElementOrdering.apply(.toBack, to: element,
                                          context: StorageService.shared.context)
            } label: {
                Image(systemName: "square.3.layers.3d.bottom.filled")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Send to Back")

            Button {
                isCropping = true
            } label: {
                Image(systemName: "crop")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
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
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Gestures

    private var imageDragGesture: some Gesture {
        // `.global` coordinate space is load-bearing. The gesture is
        // attached to the image view, and `dragOffset` (set here)
        // drives that view's `.position`. With the default `.local`
        // space, every `onChanged` tick moves the view, which shifts
        // the gesture's own coordinate frame under the finger, so the
        // next `translation` is measured against a moved origin — a
        // feedback loop that oscillates the element ~34pt per frame
        // (the "laggy / not smooth" move). Global locations don't
        // move with the view, so `translation` stays stable.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if dragOffset == .zero {
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                let proposedX = element.normalizedX + Double(dxNorm)
                let proposedY = element.normalizedY + Double(dyNorm)
                let maxX = max(0, 1 - element.normalizedWidth)
                // Cross-page hand-off: if the drag's vertical component
                // would carry the element past the top or bottom of
                // this page, ask the canvas coordinator (via the
                // shared notification) whether a sibling page can
                // host it. The coordinator owns the global y of every
                // mounted page host and is the only place that can
                // make this decision. The element's pageId / page
                // relationship + normalizedY are rewritten there;
                // SwiftData refresh notifications repaint both the
                // old and new page overlays.
                if proposedY < 0 || proposedY > 1 - element.normalizedHeight {
                    NotificationCenter.default.post(
                        name: .imageElementCrossPageHandoffRequested,
                        object: nil,
                        userInfo: [
                            "elementId": element.id,
                            "currentPageId": element.pageId,
                            "proposedNormX": proposedX,
                            "proposedNormY": proposedY
                        ]
                    )
                    dragOffset = .zero
                    return
                }
                LassoTransformUndo.withUndo(
                    elementId: element.id, actionName: "Move Image"
                ) {
                    element.normalizedX = max(0, min(maxX, proposedX))
                    element.normalizedY = max(0, min(1 - element.normalizedHeight, proposedY))
                    element.updatedAt   = Date()
                }
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
                let newW = max(Self.minNormalizedWidth, element.normalizedWidth * Double(clamped))
                let newH = element.normalizedHeight * (newW / element.normalizedWidth)
                // Cap dimensions so the far edge can't extend past the
                // page. If growth pushes through the right/bottom, cap
                // there rather than letting the element bleed off.
                let maxW = max(Self.minNormalizedWidth, 1 - element.normalizedX)
                let maxH = max(0.01, 1 - element.normalizedY)
                LassoTransformUndo.withUndo(
                    elementId: element.id, actionName: "Resize Image"
                ) {
                    element.normalizedWidth  = min(maxW, newW)
                    element.normalizedHeight = min(maxH, newH)
                    element.updatedAt        = Date()
                }
                pinchScale = 1.0
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        // `.global` for the same reason as `imageDragGesture` — the
        // corner handle's `.position` is driven by `resizeDelta`, so
        // a local-space drag feeds back on itself as the handle moves.
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if resizeDelta == nil {
                }
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                let base = CGRect(
                    x: element.normalizedX * pageSize.width,
                    y: element.normalizedY * pageSize.height,
                    width: element.normalizedWidth * pageSize.width,
                    height: element.normalizedHeight * pageSize.height
                )
                let new = resizedRect(base: base, corner: corner, translation: value.translation,
                                      freeAxis: modifierKeys.isShiftHeld)
                let normX = Double(new.minX) / Double(pageSize.width)
                let normY = Double(new.minY) / Double(pageSize.height)
                let normW = Double(new.width)  / Double(pageSize.width)
                let normH = Double(new.height) / Double(pageSize.height)
                // Clamp both origin and far edge: an element must fit
                // inside [0,1] × [0,1] on the page.
                LassoTransformUndo.withUndo(
                    elementId: element.id, actionName: "Resize Image"
                ) {
                    element.normalizedWidth  = max(Self.minNormalizedWidth, min(1, normW))
                    element.normalizedHeight = max(0.01, min(1, normH))
                    element.normalizedX = max(0, min(1 - element.normalizedWidth,  normX))
                    element.normalizedY = max(0, min(1 - element.normalizedHeight, normY))
                    element.updatedAt        = Date()
                }
                resizeDelta = nil
            }
    }

    private func rotate90() {
        // .pi/2 radians per tap. The element model uses radians
        // (consistent with TextBlock); 4 taps = full rotation.
        LassoTransformUndo.withUndo(
            elementId: element.id, actionName: "Rotate Image"
        ) {
            let next = element.rotation + .pi / 2
            let twoPi = 2 * Double.pi
            element.rotation = next.truncatingRemainder(dividingBy: twoPi)
            element.updatedAt = Date()
        }
    }

    private func clampNorm(_ v: Double) -> Double { max(0, min(1, v)) }
}

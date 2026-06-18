import PencilKit
import SwiftData
import SwiftUI
import UIKit

/// Per-page lasso surface. Mounted INSIDE the page renderer (NOT
/// at the editor level — the page's coordinate space already
/// matches the user's gesture, dodging the zoom/scroll translation
/// the editor-level alternative would need). Owns:
///
///   • The drag gesture that captures the freeform path or marquee
///     rectangle while `.lasso` is the active tool.
///   • The visual feedback (dashed accent path / dashed rect).
///   • Intersection testing on `.onEnded`. PageElement queries run
///     once per gesture — no per-frame fetch.
///   • The post-selection chrome (bounding box + delete badge +
///     corner-resize handles + rotation handle). Chrome stays
///     visible across tool changes and clears on tap-outside or
///     page change.
///
/// **Mounted per-page; selection clears when the active page
/// changes** — `LassoSelectionState` is page-scoped per the
/// architecture spec.
///
/// **v1 manipulation model.** Live element movement during drag;
/// **snap-on-release** for resize + rotate. Documented in the
/// Step 9 report. Lifting the snap restriction is a Step 9.1.
struct LassoOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let coordinateSpace: PageCoordinateSpace
    @ObservedObject private var selection = LassoSelectionState.shared
    @ObservedObject private var modifierKeys = ModifierKeyObserver.shared
    @Environment(\.theme) private var theme

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }
    private var pageSize: CGSize { coordinateSpace.baseSize }

    @State private var lassoPoints: [CGPoint] = []
    @State private var isDragging: Bool = false

    // Manipulation transient state — drives chrome preview during
    // a gesture so the user sees the bbox move/scale/rotate
    // before the model writes happen on `.onEnded`.
    @State private var dragOffset:    CGSize = .zero
    @State private var resizeScale:   CGFloat = 1
    @State private var resizeScaleX:  CGFloat = 1
    @State private var resizeScaleY:  CGFloat = 1
    @State private var rotateAngle:   CGFloat = 0
    @State private var activeManipulation: Manipulation = .none

    private enum Manipulation { case none, drag, resize, rotate }

    // MARK: - Body

    var body: some View {
        ZStack {
            // Capture layer — active only when the lasso tool is
            // selected AND no in-flight selection chrome owns the
            // gesture surface.
            if isLassoActive && !selectionForThisPage {
                lassoCaptureLayer
            }

            // In-flight lasso visual feedback.
            if isDragging, let path = currentLassoCGPath {
                Path(path)
                    .stroke(theme.accent,
                            style: StrokeStyle(lineWidth: 1.5,
                                               lineCap: .round,
                                               lineJoin: .round,
                                               dash: [6, 4]))
            }

            // Post-selection chrome. Visible whenever the singleton
            // says this page owns the selection — survives tool
            // changes per the spec.
            if selectionForThisPage {
                selectionChrome
            }
        }
        .frame(width: pageSize.width, height: pageSize.height,
               alignment: .topLeading)
        .allowsHitTesting(isLassoActive || selectionForThisPage)
        .onChange(of: viewModel.currentPage.id) { _, newId in
            // Page-scoped: navigating to a different page clears
            // the selection. The current page's overlay (now newId)
            // doesn't fire this onChange, so only "old" pages
            // observe the change and call clear once.
            if selection.pageId != nil && selection.pageId != newId {
                selection.clear()
            }
        }
    }

    // MARK: - Capture layer

    private var lassoCaptureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(lassoGesture)
    }

    private var lassoGesture: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    lassoPoints = [value.startLocation]
                }
                appendLassoPoint(value.location)
            }
            .onEnded { _ in
                isDragging = false
                guard let path = currentLassoCGPath else {
                    lassoPoints = []
                    return
                }
                commitSelection(from: path)
                lassoPoints = []
            }
    }

    private func appendLassoPoint(_ point: CGPoint) {
        // For freeform we sample at a coarse spacing so the path
        // doesn't explode on long drags; marquee only ever needs
        // first + last so we keep just those two.
        switch selection.mode {
        case .marquee:
            if lassoPoints.count >= 2 {
                lassoPoints[1] = point
            } else {
                lassoPoints.append(point)
            }
        case .freeform:
            if let last = lassoPoints.last {
                let dx = point.x - last.x
                let dy = point.y - last.y
                if dx * dx + dy * dy < 4 { return }   // ~2pt minimum spacing
            }
            lassoPoints.append(point)
        }
    }

    private var currentLassoCGPath: CGPath? {
        LassoMath.selectionPath(for: selection.mode, points: lassoPoints)
    }

    // MARK: - Commit selection

    private func commitSelection(from path: CGPath) {
        let lassoBBox = LassoMath.boundingBox(of: path)

        var elementIds:   Set<UUID> = []
        var partials:     [UUID: Set<Int>] = [:]
        var unionBounds:  CGRect? = nil

        // Fetch every element on this page once.
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let elements = (try? modelContext.fetch(descriptor)) ?? []

        #if DEBUG
        dlog("[Lasso] commit mode=\(selection.mode) points=\(lassoPoints.count) bbox=\(lassoBBox) pageSize=\(pageSize) fetched=\(elements.count) elements")
        #endif

        for element in elements {
            switch element.kind {
            case .stroke:
                guard let content = element.strokeContent,
                      let drawing = try? PKDrawing(data: content.strokeData)
                else {
                    #if DEBUG
                    dlog("[Lasso]   stroke element \(element.id.uuidString.prefix(8)) — no content/decode failed")
                    #endif
                    continue
                }
                let strokes = drawing.strokes
                guard !strokes.isEmpty else { continue }

                var matchedIndices: Set<Int> = []
                var matchedBBoxes: [CGRect] = []
                for (i, stroke) in strokes.enumerated() {
                    let bbox = stroke.renderBounds
                    // Cheap reject — if the stroke's bbox doesn't
                    // intersect the lasso's bbox, skip the check.
                    if !bbox.intersects(lassoBBox) { continue }
                    // Use the same substantial-overlap rule as non-stroke
                    // elements: select if the stroke bbox centre is inside
                    // the path OR if ≥25 % of the bbox area overlaps the
                    // path bbox. This makes the marquee tool work correctly
                    // for strokes — previously only centre containment was
                    // tested, which failed when a stroke's bbox centre fell
                    // just outside the drawn marquee rectangle.
                    if LassoMath.rectSubstantiallyInside(bbox, in: path) {
                        matchedIndices.insert(i)
                        matchedBBoxes.append(bbox)
                    }
                }
                #if DEBUG
                let firstBBox = strokes.first?.renderBounds ?? .zero
                dlog("[Lasso]   stroke element \(element.id.uuidString.prefix(8)) strokes=\(strokes.count) matched=\(matchedIndices.count) firstStrokeBBox=\(firstBBox)")
                #endif
                if matchedIndices.isEmpty { continue }
                if matchedIndices.count == strokes.count {
                    // Whole stroke element — promote to elementIds.
                    elementIds.insert(element.id)
                } else {
                    partials[element.id] = matchedIndices
                }
                for bbox in matchedBBoxes { unionBounds = unionBounds?.union(bbox) ?? bbox }

            default:
                let rect = elementRectInPagePoints(element)
                let centre = CGPoint(x: rect.midX, y: rect.midY)
                // Centre-inside OR ≥25% area overlap — see
                // `LassoMath.rectSubstantiallyInside`. The earlier
                // point-sampling rule failed cases where the lasso
                // genuinely covered a large chunk of a wide element
                // (e.g. a text block) but the centre just escaped the
                // loop, so the element was wrongly skipped.
                let hit = LassoMath.rectSubstantiallyInside(rect, in: path)
                #if DEBUG
                dlog("[Lasso]   \(element.kind) element \(element.id.uuidString.prefix(8)) rect=\(rect) centre=\(centre) contained=\(hit)")
                #endif
                if hit {
                    elementIds.insert(element.id)
                    unionBounds = unionBounds?.union(rect) ?? rect
                }
            }
        }

        #if DEBUG
        dlog("[Lasso] result — wholeElements=\(elementIds.count) partialStrokeElements=\(partials.count)")
        #endif

        selection.setSelection(
            elementIds: elementIds,
            partialStrokes: partials,
            pageId: pageId,
            bounds: unionBounds ?? .zero
        )
    }

    private func elementRectInPagePoints(_ element: PageElement) -> CGRect {
        CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width:  element.normalizedWidth  * pageSize.width,
            height: element.normalizedHeight * pageSize.height
        )
    }

    // MARK: - Selection chrome

    private var selectionForThisPage: Bool {
        selection.hasSelection && selection.pageId == pageId
    }

    private var isLassoActive: Bool {
        viewModel.selectedTool.isLassoMode
    }

    @ViewBuilder
    private var selectionChrome: some View {
        let base = selection.selectionBounds
        let displayed = chromeDisplayRect(base: base)
        let locked = selectionIsLocked()

        ZStack {
            // Background tap-outside-to-clear. Covers the whole
            // page area but only matters when the user taps
            // OUTSIDE the chrome's interactive zones.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: pageSize.width, height: pageSize.height)
                .onTapGesture { selection.clear() }

            // Bbox. For unlocked selections it carries the body
            // drag gesture; for locked selections (e.g. PDF page
            // elements that fill the page) it's tap-to-clear
            // instead — dragging the box would create a false
            // promise of movement that the model rejects, leaving
            // the chrome stranded mid-air while the element snaps
            // back. Tap-to-clear also gives the user a way out
            // when the chrome covers the whole page and the
            // background-clear layer is fully occluded.
            Group {
                if locked {
                    Rectangle()
                        .strokeBorder(theme.accent,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(theme.accent.opacity(0.05))
                        .frame(width: displayed.width, height: displayed.height)
                        .contentShape(Rectangle())
                        .position(x: displayed.midX, y: displayed.midY)
                        .onTapGesture { selection.clear() }
                } else {
                    Rectangle()
                        .strokeBorder(theme.accent,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .background(theme.accent.opacity(0.05))
                        .frame(width: displayed.width, height: displayed.height)
                        .contentShape(Rectangle())
                        .position(x: displayed.midX, y: displayed.midY)
                        .rotationEffect(.radians(rotateAngle))
                        .gesture(bodyDragGesture)
                }
            }

            // Delete badge — bottom-right of the displayed rect.
            // 44pt hit target (Apple HIG minimum) wrapping a 26pt
            // glyph so the user doesn't have to pin-prick the icon
            // exactly. Earlier the entire tappable region was the
            // 22pt SF Symbol bounds — well under the minimum.
            Button {
                LassoGroupOps.delete(selection: selection,
                                     context: modelContext)
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(theme.accent)
                    .background(Circle().fill(theme.surfaceElevated))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: displayed.maxX, y: displayed.maxY)

            // Resize + rotation chrome — hidden for locked
            // selections (their dimensions are pinned, the handles
            // would either no-op or lie about the result).
            if !locked {
                cornerHandle(at: CGPoint(x: displayed.minX, y: displayed.minY))
                cornerHandle(at: CGPoint(x: displayed.maxX, y: displayed.minY))
                cornerHandle(at: CGPoint(x: displayed.minX, y: displayed.maxY))
                cornerHandle(at: CGPoint(x: displayed.maxX, y: displayed.maxY))
                rotationHandle(displayed: displayed)
            }
        }
    }

    /// True when the selection contains any element whose
    /// dimensions are pinned (currently: `.pdfPage` filling the
    /// full page). Locked selections can't be translated, scaled,
    /// or rotated — every move would clamp back, so we hide the
    /// manipulation chrome and switch the bbox tap action from
    /// "drag" to "clear selection."
    private func selectionIsLocked() -> Bool {
        let ids = selection.selectedElementIds
        guard !ids.isEmpty, selection.partialStrokeSelections.isEmpty else { return false }
        for id in ids {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == id }
            )
            guard let el = (try? modelContext.fetch(descriptor))?.first else { continue }
            if el.kind == .pdfPage,
               el.normalizedWidth >= 0.999,
               el.normalizedHeight >= 0.999 {
                return true
            }
        }
        return false
    }

    private func chromeDisplayRect(base: CGRect) -> CGRect {
        switch activeManipulation {
        case .none:
            return base
        case .drag:
            return base.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
        case .resize:
            let cx = base.midX
            let cy = base.midY
            if modifierKeys.isShiftHeld {
                let w = base.width  * resizeScaleX
                let h = base.height * resizeScaleY
                return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
            }
            let s = resizeScale
            let w = base.width  * s
            let h = base.height * s
            return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
        case .rotate:
            return base
        }
    }

    // MARK: - Body drag

    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                activeManipulation = .drag
                // Constrain the chrome's apparent translation to the
                // axes the selection can actually commit. Text-only
                // selections can't move horizontally (text blocks span
                // the full content width and are pinned to the page
                // margin), so showing the box drifting on X creates a
                // false promise — the box snaps back to its column
                // when the user releases. Lock X when nothing in the
                // selection can move horizontally.
                let raw = value.translation
                let constrained = constrainTranslation(raw)
                dragOffset = constrained
                selection.transientOffset = constrained
                selection.isManipulating = true
            }
            .onEnded { value in
                selection.isManipulating = false
                let delta = constrainTranslation(value.translation)
                LassoGroupOps.translate(
                    selection: selection,
                    delta: delta,
                    pageSize: pageSize,
                    context: modelContext
                )
                dragOffset = .zero
                selection.transientOffset = .zero
                activeManipulation = .none
            }
    }

    /// Mask out axes the selection can't actually move along. Today
    /// the only constrained kind is `.text` (full-width, Y-only); a
    /// pure text selection therefore loses its X component so the
    /// chrome no longer drifts left/right while the underlying
    /// blocks stay column-pinned.
    private func constrainTranslation(_ raw: CGSize) -> CGSize {
        if selectionIsTextOnly() {
            return CGSize(width: 0, height: raw.height)
        }
        return raw
    }

    private func selectionIsTextOnly() -> Bool {
        let ids = selection.selectedElementIds
        guard !ids.isEmpty, selection.partialStrokeSelections.isEmpty else { return false }
        for id in ids {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == id }
            )
            guard let el = (try? modelContext.fetch(descriptor))?.first else { return false }
            if el.kind != .text { return false }
        }
        return true
    }

    // MARK: - Corner handle (resize)

    private func cornerHandle(at point: CGPoint) -> some View {
        Circle()
            .fill(theme.accent)
            .overlay(Circle().stroke(theme.surfaceElevated, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().inset(by: -10))
            .position(point)
            .gesture(resizeGesture(at: point))
    }

    private func resizeGesture(at handle: CGPoint) -> some Gesture {
        // Aspect-locked (Shift not held): scale factor from the
        // distance ratio between dragged and original corner
        // position relative to the bbox centre.
        //
        // Free-axis (Shift held): scale X and Y independently
        // from the per-axis distance ratio.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeManipulation = .resize
                selection.isManipulating = true
                resizeScale = computeScale(handle: handle, drag: value.translation)
                let (sx, sy) = computeScaleXY(handle: handle, drag: value.translation)
                resizeScaleX = sx
                resizeScaleY = sy
            }
            .onEnded { _ in
                if modifierKeys.isShiftHeld {
                    LassoGroupOps.scaleXY(
                        selection: selection,
                        scaleX: resizeScaleX,
                        scaleY: resizeScaleY,
                        pageSize: pageSize,
                        context: modelContext
                    )
                } else {
                    LassoGroupOps.scale(
                        selection: selection,
                        scale: resizeScale,
                        pageSize: pageSize,
                        context: modelContext
                    )
                }
                resizeScale  = 1
                resizeScaleX = 1
                resizeScaleY = 1
                activeManipulation = .none
                selection.isManipulating = false
            }
    }

    private func computeScale(handle: CGPoint, drag: CGSize) -> CGFloat {
        let bbox = selection.selectionBounds
        let centre = CGPoint(x: bbox.midX, y: bbox.midY)
        let originalDx = handle.x - centre.x
        let originalDy = handle.y - centre.y
        let originalDist = (originalDx * originalDx + originalDy * originalDy).squareRoot()
        guard originalDist > 1 else { return 1 }
        let newX = (handle.x + drag.width)  - centre.x
        let newY = (handle.y + drag.height) - centre.y
        let newDist = (newX * newX + newY * newY).squareRoot()
        return max(0.2, min(5.0, newDist / originalDist))
    }

    private func computeScaleXY(handle: CGPoint, drag: CGSize) -> (CGFloat, CGFloat) {
        let bbox   = selection.selectionBounds
        let centre = CGPoint(x: bbox.midX, y: bbox.midY)
        let origDx = handle.x - centre.x
        let origDy = handle.y - centre.y
        let newDx  = origDx + drag.width
        let newDy  = origDy + drag.height
        let sx = abs(origDx) > 1 ? max(0.2, min(5.0, newDx / origDx)) : 1
        let sy = abs(origDy) > 1 ? max(0.2, min(5.0, newDy / origDy)) : 1
        return (sx, sy)
    }

    // MARK: - Rotation handle

    private func rotationHandle(displayed: CGRect) -> some View {
        let topCentre = CGPoint(x: displayed.midX, y: displayed.minY)
        let knob      = CGPoint(x: displayed.midX, y: displayed.minY - 22)

        return ZStack {
            Path { p in
                p.move(to: topCentre)
                p.addLine(to: knob)
            }
            .stroke(theme.accent.opacity(0.4), lineWidth: 1)

            Circle()
                .fill(theme.accent)
                .overlay(Circle().stroke(theme.surfaceElevated, lineWidth: 1.5))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle().inset(by: -12))
                .position(knob)
                .gesture(rotateGesture(knob: knob))
        }
    }

    private func rotateGesture(knob: CGPoint) -> some Gesture {
        let centre = CGPoint(x: selection.selectionBounds.midX,
                             y: selection.selectionBounds.midY)
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeManipulation = .rotate
                selection.isManipulating = true
                rotateAngle = angle(from: knob, to: value.location, around: centre)
            }
            .onEnded { _ in
                let θ = rotateAngle
                LassoGroupOps.rotate(
                    selection: selection,
                    angle: θ,
                    pageSize: pageSize,
                    context: modelContext
                )
                rotateAngle = 0
                activeManipulation = .none
                selection.isManipulating = false
            }
    }

    private func angle(from origin: CGPoint, to current: CGPoint, around centre: CGPoint) -> CGFloat {
        let v0 = CGVector(dx: origin.x  - centre.x, dy: origin.y  - centre.y)
        let v1 = CGVector(dx: current.x - centre.x, dy: current.y - centre.y)
        let a0 = atan2(v0.dy, v0.dx)
        let a1 = atan2(v1.dy, v1.dx)
        return a1 - a0
    }
}

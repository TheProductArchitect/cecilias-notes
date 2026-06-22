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
    @State private var resizeTranslation: CGSize = .zero
    @State private var activeCorner: Corner = .bottomRight
    @State private var rotateAngle:   CGFloat = 0
    @State private var activeManipulation: Manipulation = .none

    private enum Manipulation { case none, drag, resize, rotate }

    /// Which corner of the selection bbox the user is grabbing.
    /// Drives the resize gesture's anchor: the OPPOSITE corner
    /// stays fixed while the grabbed corner follows the finger.
    /// This matches every direct-manipulation tool the user
    /// already knows (Photos / Pages / Notability) where dragging
    /// the bottom-right corner outward grows the box rightward
    /// and downward while the top-left edge stays put.
    enum Corner: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight

        /// The OPPOSITE-corner anchor point of `rect`, in `rect`'s
        /// coordinate space. The element-scale commit pivots
        /// around this point so the chrome preview and the
        /// committed positions agree.
        func anchor(in rect: CGRect) -> CGPoint {
            switch self {
            case .topLeft:     return CGPoint(x: rect.maxX, y: rect.maxY)
            case .topRight:    return CGPoint(x: rect.minX, y: rect.maxY)
            case .bottomLeft:  return CGPoint(x: rect.maxX, y: rect.minY)
            case .bottomRight: return CGPoint(x: rect.minX, y: rect.minY)
            }
        }
    }

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
        // Flush any in-flight canvas drawings before the fetch.
        // canvasViewDrawingDidChange debounces persistence by ~1.2s;
        // a user who draws then immediately lassoes within that
        // window would otherwise see no strokes selected because
        // StrokeContent.strokeData hasn't been written yet.
        viewModel.canvasFlushAllHandler?()

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

            // Delete badge — anchored OUTSIDE the bbox at the
            // top-right corner so it can't overlap with the
            // bottom-right resize handle (it used to sit at
            // `(maxX, maxY)`, same coordinate as the corner
            // handle, and the 44pt hit target swallowed taps
            // intended for the resize handle).
            //
            // Hidden during rotation because the rest of the
            // chrome is hidden too — leaving just the delete
            // floating at an unrotated corner would look broken.
            if activeManipulation != .rotate {
                // Place the delete badge OUTSIDE the chrome's top-
                // right corner by default, but clamp the centre so
                // the 44pt hit target stays fully inside the page.
                // Without the clamp the badge floats into the
                // gutter beside the notebook (or above the masthead)
                // and the user can't tap it.
                let badgeRadius: CGFloat = 22
                let badgeX = max(badgeRadius,
                                 min(pageSize.width  - badgeRadius,
                                     displayed.maxX + 24))
                let badgeY = max(badgeRadius,
                                 min(pageSize.height - badgeRadius,
                                     displayed.minY - 24))
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
                .position(x: badgeX, y: badgeY)
            }

            // Resize + rotation chrome — hidden for locked
            // selections (their dimensions are pinned, the handles
            // would either no-op or lie about the result).
            // Also hidden mid-rotation: the corner handles are
            // anchored to the unrotated bbox corners, so they
            // visibly desync from the rotated dashed rectangle
            // and confuse the user about where to grab next.
            if !locked, activeManipulation != .rotate {
                cornerHandle(corner: .topLeft,
                             at: CGPoint(x: displayed.minX, y: displayed.minY))
                cornerHandle(corner: .topRight,
                             at: CGPoint(x: displayed.maxX, y: displayed.minY))
                cornerHandle(corner: .bottomLeft,
                             at: CGPoint(x: displayed.minX, y: displayed.maxY))
                cornerHandle(corner: .bottomRight,
                             at: CGPoint(x: displayed.maxX, y: displayed.maxY))
            }
            // Rotation knob stays visible — it follows the rotated
            // bbox by computing the rotated "top of the box" point
            // directly, so the user can keep dragging from the
            // same conceptual handle as the rectangle spins.
            if !locked {
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

    /// Restrict an arbitrary rect so the chrome cannot extend past
    /// the page bounds. The selection bbox itself can legitimately
    /// land mid-drag at the edge — but rendering its border 100pt
    /// off-page shows the user an empty blue box hovering in the
    /// gutter beside the notebook, which they called out as broken.
    /// We still permit the chrome to *touch* the edge so the
    /// in-bounds case is unchanged.
    private func clampToPage(_ rect: CGRect) -> CGRect {
        let maxW = pageSize.width
        let maxH = pageSize.height
        var x = max(0, min(maxW, rect.minX))
        var y = max(0, min(maxH, rect.minY))
        let xEnd = max(0, min(maxW, rect.maxX))
        let yEnd = max(0, min(maxH, rect.maxY))
        let w = max(0, xEnd - x)
        let h = max(0, yEnd - y)
        // Preserve at least 1pt so SwiftUI doesn't collapse the
        // chrome into invisibility when the user drags right onto
        // the edge.
        if w < 1 { x = max(0, min(maxW - 1, x)); }
        if h < 1 { y = max(0, min(maxH - 1, y)); }
        return CGRect(x: x, y: y, width: max(1, w), height: max(1, h))
    }

    private func chromeDisplayRect(base: CGRect) -> CGRect {
        let raw = rawChromeDisplayRect(base: base)
        return clampToPage(raw)
    }

    private func rawChromeDisplayRect(base: CGRect) -> CGRect {
        switch activeManipulation {
        case .none:
            return base
        case .drag:
            return base.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
        case .resize:
            // Opposite-corner anchor: the two edges that share the
            // grabbed corner follow the finger; the other two
            // stay fixed. Direct-manipulation behaviour every
            // direct-manipulation tool (Photos, Pages, Notability)
            // uses by default. The earlier center-anchored model
            // moved every edge symmetrically — pulling the bottom-
            // right corner outward also pushed the top-left edge
            // outward, which the user explicitly called out as
            // wrong: "expand the two edges the vertex is connected
            // to, not the whole thing."
            let dx = resizeTranslation.width
            let dy = resizeTranslation.height
            var x = base.minX, y = base.minY, w = base.width, h = base.height
            switch activeCorner {
            case .topLeft:
                x += dx; y += dy; w -= dx; h -= dy
            case .topRight:
                y += dy; w += dx; h -= dy
            case .bottomLeft:
                x += dx; w -= dx; h += dy
            case .bottomRight:
                w += dx; h += dy
            }
            // Clamp to a sane minimum without breaking the anchor:
            // if width / height would go below the minimum, pin
            // the dragged corner so the anchor edge stays put.
            let minSide: CGFloat = 20
            if w < minSide {
                if activeCorner == .topLeft || activeCorner == .bottomLeft {
                    x = base.maxX - minSide
                }
                w = minSide
            }
            if h < minSide {
                if activeCorner == .topLeft || activeCorner == .topRight {
                    y = base.maxY - minSide
                }
                h = minSide
            }
            return CGRect(x: x, y: y, width: w, height: h)
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
                LassoLiveDrag.shared.transientOffset = constrained
                LassoLiveDrag.shared.isManipulating = true
            }
            .onEnded { value in
                LassoLiveDrag.shared.isManipulating = false
                let delta = constrainTranslation(value.translation)
                LassoGroupOps.translate(
                    selection: selection,
                    delta: delta,
                    pageSize: pageSize,
                    context: modelContext
                )
                dragOffset = .zero
                LassoLiveDrag.shared.transientOffset = .zero
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

    private func cornerHandle(corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(theme.accent)
            .overlay(Circle().stroke(theme.surfaceElevated, lineWidth: 1.5))
            .frame(width: 12, height: 12)
            .contentShape(Rectangle().inset(by: -10))
            .position(point)
            .gesture(resizeGesture(corner: corner))
    }

    private func resizeGesture(corner: Corner) -> some Gesture {
        // Live translation feeds `chromeDisplayRect` directly so
        // the dragged corner stays under the finger and the
        // opposite corner stays nailed in place. On release we
        // compute the equivalent scale factors and commit through
        // `LassoGroupOps.scaleXY(..., anchor:)`.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeManipulation = .resize
                activeCorner = corner
                resizeTranslation = value.translation
                LassoLiveDrag.shared.isManipulating = true
            }
            .onEnded { value in
                let base = selection.selectionBounds
                let finalRect = chromeDisplayRect(base: base)
                let scaleX = base.width  > 0.001 ? finalRect.width  / base.width  : 1
                let scaleY = base.height > 0.001 ? finalRect.height / base.height : 1
                let anchor = corner.anchor(in: base)
                LassoGroupOps.scaleXY(
                    selection: selection,
                    scaleX: scaleX,
                    scaleY: scaleY,
                    pageSize: pageSize,
                    anchor: anchor,
                    context: modelContext
                )
                resizeTranslation = .zero
                resizeScale  = 1
                resizeScaleX = 1
                resizeScaleY = 1
                activeManipulation = .none
                LassoLiveDrag.shared.isManipulating = false
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
        // Compute the knob position in rotated bbox space so the
        // handle visibly follows the dashed rectangle as the user
        // drags. The bbox itself rotates around its centre via
        // `.rotationEffect(.radians(rotateAngle))`; the knob has
        // to track that same rotation by hand because it lives
        // outside the bbox view in the ZStack.
        let centre = CGPoint(x: displayed.midX, y: displayed.midY)
        let knobOffset = displayed.height / 2 + 22
        let topCentreOffset = displayed.height / 2
        let cosA = cos(rotateAngle)
        let sinA = sin(rotateAngle)
        let topCentre = CGPoint(
            x: centre.x + topCentreOffset * sinA,
            y: centre.y - topCentreOffset * cosA
        )
        let knob = CGPoint(
            x: centre.x + knobOffset * sinA,
            y: centre.y - knobOffset * cosA
        )

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
                .gesture(rotateGesture(centre: centre))
        }
    }

    private func rotateGesture(centre: CGPoint) -> some Gesture {
        // Track the angle from the gesture's `startLocation` →
        // `value.location`, both relative to the bbox centre. The
        // earlier implementation read the knob position at gesture
        // creation time — but the knob position is captured in the
        // view-builder closure once, and on the second rotation
        // pass the captured "origin" was the already-rotated knob
        // from the previous gesture. Using `startLocation` is
        // gesture-local and immune to that staleness.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeManipulation = .rotate
                LassoLiveDrag.shared.isManipulating = true
                LassoLiveDrag.shared.rotationCenter = centre
                let a = angle(
                    from: value.startLocation,
                    to: value.location,
                    around: centre
                )
                rotateAngle = a
                // Publish the live angle so every selected element
                // can rotate with the bbox preview instead of
                // standing still and snapping on release.
                LassoLiveDrag.shared.rotationAngle = a
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
                LassoLiveDrag.shared.isManipulating = false
                LassoLiveDrag.shared.rotationAngle = 0
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

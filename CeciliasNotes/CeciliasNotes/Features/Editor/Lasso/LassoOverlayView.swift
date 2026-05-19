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
    @State private var dragOffset:   CGSize = .zero
    @State private var resizeScale:  CGFloat = 1
    @State private var rotateAngle:  CGFloat = 0
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

        for element in elements {
            switch element.kind {
            case .stroke:
                guard let content = element.strokeContent,
                      let drawing = try? PKDrawing(data: content.strokeData)
                else { continue }
                let strokes = drawing.strokes
                guard !strokes.isEmpty else { continue }

                var matchedIndices: Set<Int> = []
                var matchedBBoxes: [CGRect] = []
                for (i, stroke) in strokes.enumerated() {
                    let bbox = stroke.renderBounds
                    // Cheap reject — if the stroke's bbox doesn't
                    // intersect the lasso's bbox, skip the centre check.
                    if !bbox.intersects(lassoBBox) { continue }
                    if LassoMath.rectCentreContained(bbox, in: path) {
                        matchedIndices.insert(i)
                        matchedBBoxes.append(bbox)
                    }
                }
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
                if LassoMath.rectCentreContained(rect, in: path) {
                    elementIds.insert(element.id)
                    unionBounds = unionBounds?.union(rect) ?? rect
                }
            }
        }

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

        ZStack {
            // Background tap-outside-to-clear. Covers the whole
            // page area but only matters when the user taps
            // OUTSIDE the chrome's interactive zones.
            Color.clear
                .contentShape(Rectangle())
                .frame(width: pageSize.width, height: pageSize.height)
                .onTapGesture { selection.clear() }

            // Bbox + body drag.
            Rectangle()
                .strokeBorder(theme.accent,
                              style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                .background(theme.accent.opacity(0.05))
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .position(x: displayed.midX, y: displayed.midY)
                .rotationEffect(.radians(rotateAngle))
                .gesture(bodyDragGesture)

            // Delete badge — bottom-right of the displayed rect.
            Button {
                LassoGroupOps.delete(selection: selection,
                                     context: modelContext)
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                    .background(Circle().fill(theme.surfaceElevated))
            }
            .buttonStyle(.plain)
            .position(x: displayed.maxX - 14, y: displayed.maxY - 14)

            // Corner-resize handles (4). Snap-on-release.
            cornerHandle(at: CGPoint(x: displayed.minX, y: displayed.minY))
            cornerHandle(at: CGPoint(x: displayed.maxX, y: displayed.minY))
            cornerHandle(at: CGPoint(x: displayed.minX, y: displayed.maxY))
            cornerHandle(at: CGPoint(x: displayed.maxX, y: displayed.maxY))

            // Rotation handle — 18pt above the top-centre of the
            // displayed rect, with a 1pt tether line.
            rotationHandle(displayed: displayed)
        }
    }

    private func chromeDisplayRect(base: CGRect) -> CGRect {
        switch activeManipulation {
        case .none:
            return base
        case .drag:
            return base.offsetBy(dx: dragOffset.width, dy: dragOffset.height)
        case .resize:
            let s = resizeScale
            let cx = base.midX
            let cy = base.midY
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
                dragOffset = value.translation
                selection.transientOffset = value.translation
                selection.isManipulating = true
            }
            .onEnded { value in
                selection.isManipulating = false
                let delta = CGSize(
                    width:  value.translation.width,
                    height: value.translation.height
                )
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
        // Scale factor derived from the distance from the bbox
        // centre to the dragged corner, divided by the original
        // distance to that same corner. Aspect-locked.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                activeManipulation = .resize
                selection.isManipulating = true
                resizeScale = computeScale(handle: handle, drag: value.translation)
            }
            .onEnded { _ in
                let s = resizeScale
                LassoGroupOps.scale(
                    selection: selection,
                    scale: s,
                    pageSize: pageSize,
                    context: modelContext
                )
                resizeScale = 1
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
        let raw = newDist / originalDist
        return max(0.2, min(5.0, raw))
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

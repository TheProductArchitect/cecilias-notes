import SwiftData
import SwiftUI

/// Per-page render layer for V6 `PageElement`s of kind `.shape`.
///
/// Renders every persisted shape on the page (rectangle / ellipse /
/// triangle / line / arrow / star / heart / callout) and captures
/// drag input when the shape tool is active to create new ones.
///
/// Selection / resize / recolour are tracked under "shape selection
/// polish" — this overlay ships the create + display path.
struct ShapeElementsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    @Environment(\.theme) private var theme

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    /// In-flight drag preview. The user starts a drag on a shape
    /// tool; we render a translucent preview at that rect until
    /// release, at which point we persist the element.
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var refreshTick: Int = 0

    private var pageSize: CGSize { coordinateSpace.baseSize }

    private var elements: [PageElement] {
        let _ = refreshTick
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex)]
        )
        let all = (try? modelContext.fetch(descriptor)) ?? []
        return all.filter { $0.kind == .shape }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Persisted shapes. In cursor mode each shape is tap-
            // selectable — the tap populates LassoSelectionState
            // with the shape's element id, which causes
            // LassoOverlayView to draw its bounding-box chrome (4
            // corner handles, rotation handle, body-drag area, 44pt
            // delete button) over the shape. Reusing the lasso
            // chrome avoids a parallel selection / handle / delete
            // implementation just for shapes.
            ForEach(elements, id: \.id) { element in
                if let content = element.shapeContent {
                    renderShapeFramed(element: element, content: content)
                }
            }

            // In-flight preview while the user is drawing.
            if let kind = viewModel.selectedTool.currentShapeKind,
               let start = dragStart, let current = dragCurrent {
                let rect = normalizedRect(from: start, to: current)
                ShapeKindPath.path(for: kind, in: rect)
                    .stroke(theme.accent, lineWidth: 2)
                    .opacity(0.85)
            }

            // Drag-capture surface when the shape tool is active.
            // Sits on top of the persisted shapes so the user can
            // drag freely without the overlays below it consuming
            // the gesture.
            if viewModel.selectedTool.isShapeMode {
                // Pencil-only drag when a Pencil has been detected
                // on the device; finger drags also create shapes
                // when no Pencil has been seen (so users without a
                // Pencil aren't locked out). Mirrors the
                // FingerDrawingMode logic the PKCanvasView uses.
                PencilFingerDragSurface(
                    acceptsFinger: !InputCapabilityDetector.shared.hasPencil,
                    onBegan: { location in
                        dragStart = location
                        dragCurrent = location
                    },
                    onChanged: { location in
                        dragCurrent = location
                    },
                    onEnded: { location, cancelled in
                        defer {
                            dragStart = nil
                            dragCurrent = nil
                        }
                        guard !cancelled,
                              let kind = viewModel.selectedTool.currentShapeKind,
                              let start = dragStart
                        else { return }
                        let rect = normalizedRect(from: start, to: location)
                        createShape(kind: kind, in: rect)
                    }
                )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .shapeElementsChanged)) { note in
            // Cross-page handoff carries the source page's id so the
            // SOURCE overlay can refresh one runloop tick later than
            // the DESTINATION. Without that delay both overlays
            // refresh on the same tick and the SwiftUI render commit
            // briefly shows neither: the source drops the element
            // immediately, the destination's first render of the
            // newly-mounted element lands on the next frame, and the
            // user sees a one-frame "shape disappeared" flicker.
            // Deferring the source by a tick lets the destination
            // commit first.
            if let info = note.userInfo,
               let srcId = info["sourcePageId"] as? UUID,
               srcId == pageId {
                DispatchQueue.main.async { refreshTick &+= 1 }
            } else {
                refreshTick &+= 1
            }
        }
    }

    /// Wraps `renderShape` in a frame anchored at the element's
    /// bounding rect with cursor-mode tap-to-select. The framed
    /// container is what catches the tap (thin outlines like a
    /// line or open arrow are hard to hit-test directly).
    @ViewBuilder
    private func renderShapeFramed(element: PageElement, content: ShapeContent) -> some View {
        let rect = CGRect(
            x: CGFloat(element.normalizedX)      * pageSize.width,
            y: CGFloat(element.normalizedY)      * pageSize.height,
            width:  CGFloat(element.normalizedWidth)  * pageSize.width,
            height: CGFloat(element.normalizedHeight) * pageSize.height
        )
        renderShape(element: element, content: content)
            .frame(width: rect.width, height: rect.height)
            .contentShape(Rectangle())
            .onTapGesture {
                guard viewModel.selectedTool.isCursorMode else { return }
                selectViaLasso(element: element)
            }
            .allowsHitTesting(viewModel.selectedTool.isCursorMode)
            .position(x: rect.midX, y: rect.midY)
    }

    /// Populate `LassoSelectionState` with this single shape so
    /// `LassoOverlayView` renders its move + resize + delete
    /// chrome. Single-element selection — the bounds are the
    /// shape's normalised rect in page-pt.
    private func selectViaLasso(element: PageElement) {
        let bounds = CGRect(
            x: element.normalizedX      * pageSize.width,
            y: element.normalizedY      * pageSize.height,
            width:  element.normalizedWidth  * pageSize.width,
            height: element.normalizedHeight * pageSize.height
        )
        LassoSelectionState.shared.setSelection(
            elementIds: [element.id],
            partialStrokes: [:],
            pageId: pageId,
            bounds: bounds
        )
        HapticManager.shared.toolSwitched()
    }

    /// Renders the shape's path inside its own local (0,0,w,h)
    /// coordinate space. Caller frames + positions this view at the
    /// element's bbox via `renderShapeFramed`. Local coords let the
    /// hit-test rectangle and the visible drawing share the same
    /// frame so the cursor-mode tap region matches what the user
    /// sees on screen.
    @ViewBuilder
    private func renderShape(element: PageElement, content: ShapeContent) -> some View {
        let localRect = CGRect(
            x: 0,
            y: 0,
            width:  CGFloat(element.normalizedWidth)  * pageSize.width,
            height: CGFloat(element.normalizedHeight) * pageSize.height
        )
        let strokeColor: Color = content.strokeColorHex.isEmpty
            ? theme.foreground
            : Color(uiColor: UIColor(hex: content.strokeColorHex))
        let lineWidth = max(1, CGFloat(content.strokeWidth > 0 ? content.strokeWidth : 2))
        let path = ShapeKindPath.path(for: content.shapeKind, in: localRect)

        if let fillHex = content.fillColorHex, !fillHex.isEmpty {
            path
                .fill(Color(uiColor: UIColor(hex: fillHex)).opacity(content.fillOpacity))
                .overlay(path.stroke(strokeColor, lineWidth: lineWidth))
        } else {
            path.stroke(strokeColor, lineWidth: lineWidth)
        }
    }

    /// Normalises two points into a non-negative-size rect so the
    /// user can draw in any direction.
    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width:  max(1, abs(b.x - a.x)),
            height: max(1, abs(b.y - a.y))
        )
    }

    private func createShape(kind: ShapeKind, in rect: CGRect) {
        guard DeviceCapabilities.canMutate else { return }
        // Tiny accidental taps shouldn't spawn 1×1pt shapes — require
        // at least 12pt on the longer axis before we commit.
        guard max(rect.width, rect.height) >= 12 else { return }

        let normX = max(0, min(1, Double(rect.minX / pageSize.width)))
        let normY = max(0, min(1, Double(rect.minY / pageSize.height)))
        let normW = max(0.01, min(1, Double(rect.width  / pageSize.width)))
        let normH = max(0.01, min(1, Double(rect.height / pageSize.height)))
        let maxZ  = elements.map(\.zIndex).max() ?? 0

        let element = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .shape,
            normalizedX: normX,
            normalizedY: normY,
            normalizedWidth: normW,
            normalizedHeight: normH,
            zIndex: maxZ + 1
        )
        // Leave strokeColorHex empty so the renderer falls back to
        // the live theme.foreground colour at draw time — auto-flips
        // when the user switches between default / midnight themes
        // without needing a per-element migration.
        let content = ShapeContent(
            shapeKind: kind,
            strokeColorHex: "",
            strokeWidth: 2,
            strokeStyle: .solid
        )
        element.shapeContent = content
        modelContext.insert(element)

        do {
            try modelContext.save()
        } catch {
            #if DEBUG
            dlog("[ShapeElement] save failed: \(error)")
            #endif
        }
        refreshTick &+= 1
        NotificationCenter.default.post(name: .shapeElementsChanged, object: nil)
        PageElementUndo.registerCreate(
            elementId: element.id,
            kind: .shape,
            canvas: viewModel.canvasView,
            actionName: "Create Shape"
        )
        // Auto-add a fresh page if this shape just landed in the
        // lower third of the last page and the user has auto-add
        // enabled. Mirrors the stroke-driven path in
        // ContinuousCanvasView.considerAutoAddAfterStroke so the
        // user reaches the same "infinite scroll" behaviour
        // regardless of whether they ink, draw shapes, or stick
        // notes. The user reported this gap explicitly.
        viewModel.considerAutoAddAfterElement(
            onPageId: pageId,
            normalizedMaxY: normY + normH
        )
    }
}

extension Notification.Name {
    /// Posted after a shape element is inserted/deleted so other
    /// overlays / state can refresh without polling SwiftData.
    static let shapeElementsChanged = Notification.Name("editor.shapeElementsChanged")

    /// Fired by an image element's drag handler when the proposed
    /// drop position lands above or below the current page bounds.
    /// The canvas coordinator listens and rewrites the element's
    /// pageId + normalizedY against the destination page's
    /// coordinate space. userInfo carries:
    ///   - elementId: UUID of the dragged element
    ///   - currentPageId: UUID of the page the drag started on
    ///   - proposedNormX: Double, the dragged X in source-page space
    ///   - proposedNormY: Double, the dragged Y (may be < 0 or > 1)
    static let imageElementCrossPageHandoffRequested = Notification.Name("editor.imageElementCrossPageHandoffRequested")
}

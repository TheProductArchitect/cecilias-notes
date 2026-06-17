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
            // Persisted shapes — read-only render for now. Selection
            // + handle dragging will land in a follow-up commit.
            ForEach(elements, id: \.id) { element in
                if let content = element.shapeContent {
                    renderShape(element: element, content: content)
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
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 4, coordinateSpace: .local)
                            .onChanged { value in
                                if dragStart == nil { dragStart = value.startLocation }
                                dragCurrent = value.location
                            }
                            .onEnded { value in
                                defer {
                                    dragStart = nil
                                    dragCurrent = nil
                                }
                                guard let kind = viewModel.selectedTool.currentShapeKind,
                                      let start = dragStart
                                else { return }
                                let rect = normalizedRect(from: start, to: value.location)
                                createShape(kind: kind, in: rect)
                            }
                    )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onReceive(NotificationCenter.default.publisher(for: .shapeElementsChanged)) { _ in
            refreshTick &+= 1
        }
    }

    @ViewBuilder
    private func renderShape(element: PageElement, content: ShapeContent) -> some View {
        let rect = CGRect(
            x: CGFloat(element.normalizedX)      * pageSize.width,
            y: CGFloat(element.normalizedY)      * pageSize.height,
            width:  CGFloat(element.normalizedWidth)  * pageSize.width,
            height: CGFloat(element.normalizedHeight) * pageSize.height
        )
        let strokeColor: Color = content.strokeColorHex.isEmpty
            ? theme.foreground
            : Color(uiColor: UIColor(hex: content.strokeColorHex))
        let lineWidth = max(1, CGFloat(content.strokeWidth > 0 ? content.strokeWidth : 2))
        let path = ShapeKindPath.path(for: content.shapeKind, in: rect)

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
    }
}

extension Notification.Name {
    /// Posted after a shape element is inserted/deleted so other
    /// overlays / state can refresh without polling SwiftData.
    static let shapeElementsChanged = Notification.Name("editor.shapeElementsChanged")
}

import SwiftData
import SwiftUI

/// Per-page render layer for V6 `PageElement(kind: .stroke)`.
/// Step 8 — the last PageElement-backed surface in the unified
/// migration. **Visually transparent.** The actual stroke render
/// stays on PKCanvasView, mounted separately by
/// `ContinuousCanvasView.mountCanvas`. This overlay exists so the
/// stroke primitive participates in the per-page overlay pattern
/// (binding, lifecycle, Step 9 lasso hook).
///
/// On first mount for a page that has no stroke element yet
/// (freshly-created page), the overlay calls
/// `StrokeCommit.ensureStrokeElement` to seed the singleton. The
/// canvas coordinator can then save into it without a separate
/// "does the element exist yet?" check on every drawing change.
struct StrokeElementsOverlayView: View {

    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    private var modelContext: ModelContext {
        StorageService.shared.container.mainContext
    }

    private var pageSize: CGSize { coordinateSpace.baseSize }

    @State private var seeded: Bool = false

    var body: some View {
        Color.clear
            .frame(width: pageSize.width, height: pageSize.height)
            .allowsHitTesting(false)
            .task(id: pageId) {
                guard !seeded else { return }
                _ = StrokeCommit.ensureStrokeElement(
                    forPageId: pageId,
                    notebookId: notebookId,
                    context: modelContext
                )
                seeded = true
            }
    }
}

import CoreGraphics
import Foundation
import PencilKit
import SwiftData

/// SwiftData commit helpers for highlight creation. Mirrors the
/// pattern established by `AudioElementCommit` (Step 5) and
/// `DictationFlowCommit` (Step 6): one entry point that owns the
/// row inserts + the change-notification post.
///
/// Step 5.5: replaces direct `PDFTextAnnotationStore.save(...)`
/// calls from the highlighter detection pipeline
/// (`EditorViewModel+Highlighter`). Each user-visible highlight
/// becomes one `PageElement(.highlight) + HighlightContent` per
/// rect; multi-line selections share a `groupId` so the
/// overlay's delete handler can remove them together.
@MainActor
enum HighlightCommit {

    /// Insert one or more highlights as a single logical group.
    /// Each rect → one PageElement + HighlightContent row. When
    /// `rects.count > 1` a shared `groupId` is generated; single-
    /// rect selections pass `nil` so the overlay's delete handler
    /// fast-paths to one row.
    ///
    /// `rects` are in normalised PDF-page coordinates
    /// ([0, 1]^2, top-left origin) — the renderer composes them
    /// against the parent PDFPageContent's element bounds at draw
    /// time.
    @discardableResult
    static func createHighlights(
        rects: [CGRect],
        pdfPageContentId: UUID,
        pageId: UUID,
        notebookId: UUID,
        style: HighlightStyle = .highlight,
        colorVariant: String = "yellow",
        capturedText: String? = nil,
        canvas: PKCanvasView? = nil
    ) -> [UUID] {
        guard !rects.isEmpty else { return [] }
        let context = StorageService.shared.context
        let groupId: UUID? = rects.count > 1 ? UUID() : nil
        let baseZIndex = nextZIndex(forPageId: pageId, context: context)

        var createdIds: [UUID] = []
        for (offset, rect) in rects.enumerated() {
            let element = PageElement(
                id: UUID(),
                pageId: pageId,
                notebookId: notebookId,
                kind: .highlight,
                normalizedX: 0,         // highlight projection
                normalizedY: 0,         // is parent-relative —
                normalizedWidth: 0,     // these are unused by
                normalizedHeight: 0,    // the overlay's render path
                zIndex: baseZIndex + offset
            )
            let content = HighlightContent(
                id: UUID(),
                pdfPageContentId: pdfPageContentId,
                rectOriginX: Double(rect.origin.x),
                rectOriginY: Double(rect.origin.y),
                rectWidth:   Double(rect.width),
                rectHeight:  Double(rect.height),
                style: style,
                colorVariant: colorVariant,
                groupId: groupId,
                capturedText: capturedText
            )
            element.highlightContent = content
            context.insert(element)
            createdIds.append(element.id)
        }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[HighlightCommit] save failed: \(error)")
            #endif
        }
        // One grouped undo entry for the whole multi-line highlight
        // — a single ⌘Z removes every rect, matching how the user
        // perceives the gesture (one highlight, not N lines).
        if let manager = canvas?.undoManager {
            manager.beginUndoGrouping()
            for id in createdIds {
                PageElementUndo.registerCreate(
                    elementId: id,
                    kind: .highlight,
                    canvas: canvas,
                    actionName: "Highlight"
                )
            }
            manager.endUndoGrouping()
        }
        NotificationCenter.default.post(name: .highlightElementsChanged, object: nil)
        return createdIds
    }

    /// Soft-delete every highlight sharing a `groupId`. Standalone
    /// highlights (nil groupId) should use the overlay's per-
    /// element delete path instead; this helper is for explicit
    /// "delete this whole multi-line highlight" callers.
    static func deleteHighlightGroup(groupId: UUID) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<HighlightContent>(
            predicate: #Predicate { $0.groupId == groupId }
        )
        let contents = (try? context.fetch(descriptor)) ?? []
        let now = Date()
        for content in contents {
            content.element?.deletedAt = now
            content.element?.updatedAt = now
        }
        try? context.save()
        NotificationCenter.default.post(name: .highlightElementsChanged, object: nil)
    }

    // MARK: - Helpers

    private static func nextZIndex(forPageId pageId: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex, order: .reverse)]
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return (elements.first?.zIndex ?? 0) + 1
    }
}

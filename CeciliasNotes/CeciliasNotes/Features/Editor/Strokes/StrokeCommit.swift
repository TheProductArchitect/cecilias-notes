import Foundation
import PencilKit
import SwiftData

/// Centralised create / read / update for the per-page stroke
/// singleton — `PageElement(kind: .stroke) + StrokeContent`.
/// Mirrors `HighlightCommit` / `StickyNoteCommit` so callers don't
/// have to re-derive the SwiftData wiring.
///
/// **One PageElement per page.** Every helper here assumes there is
/// at most one active stroke element per `pageId`. `ensureStrokeElement`
/// returns the existing one if present, creates a new one if not.
enum StrokeCommit {

    // MARK: - Ensure / fetch

    /// Returns the active stroke element + content for a page,
    /// creating both if they don't exist yet. Idempotent — call
    /// it from anywhere (canvas mount, save, lasso) and you get
    /// the same singleton back.
    @MainActor
    @discardableResult
    static func ensureStrokeElement(
        forPageId pageId: UUID,
        notebookId: UUID,
        context: ModelContext? = nil
    ) -> (element: PageElement, content: StrokeContent)? {
        let context = context ?? StorageService.shared.context
        if let existing = strokeElement(forPageId: pageId, context: context) {
            if let content = existing.strokeContent {
                return (existing, content)
            }
            // Element without content — rare, but recover by attaching
            // a fresh StrokeContent rather than orphaning.
            let content = StrokeContent()
            existing.strokeContent = content
            try? context.save()
            return (existing, content)
        }

        let element = PageElement(
            pageId:           pageId,
            notebookId:       notebookId,
            kind:             .stroke,
            normalizedX:      0,
            normalizedY:      0,
            normalizedWidth:  1,
            normalizedHeight: 1,
            zIndex:           1_000  // strokes render on top of every other PageElement primitive
        )
        let content = StrokeContent()
        element.strokeContent = content
        context.insert(element)
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[StrokeCommit] ensureStrokeElement save failed: \(error)")
            #endif
            return nil
        }
        return (element, content)
    }

    /// Find the active (non-soft-deleted) stroke element for a
    /// page, or `nil` if none. Filter `kind == .stroke` post-fetch
    /// in Swift (iOS 26 `#Predicate` enum-case-equality
    /// limitation, same workaround as the other element kinds).
    @MainActor
    static func strokeElement(
        forPageId pageId: UUID,
        context: ModelContext? = nil
    ) -> PageElement? {
        let context = context ?? StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.first { $0.kind == .stroke }
    }

    // MARK: - Write

    /// Persist a fresh `PKDrawing` for the page's stroke singleton
    /// and write through to `StrokeCache`. Caller is responsible
    /// for debouncing — every call here saves SwiftData
    /// synchronously. Returns `true` on success.
    @discardableResult
    @MainActor
    static func updateDrawing(
        forPageId pageId: UUID,
        notebookId: UUID,
        drawing: PKDrawing,
        context: ModelContext? = nil
    ) -> Bool {
        let context = context ?? StorageService.shared.context
        guard let pair = ensureStrokeElement(
            forPageId: pageId,
            notebookId: notebookId,
            context: context
        ) else { return false }
        let data = drawing.dataRepresentation()
        pair.content.strokeData = data
        pair.content.updatedAt  = Date()
        pair.element.updatedAt  = Date()
        stampPage(pageId: pageId, context: context)
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[StrokeCommit] updateDrawing save failed: \(error)")
            #endif
            return false
        }
        // Write-through to the in-memory cache so the next canvas
        // mount on this page hits without re-decoding.
        StrokeCache.shared.cache(drawing, forPage: pageId)
        return true
    }

    /// Bump the owning page's `updatedAt` after a stroke rewrite
    /// that bypasses `StorageService.updatePageStrokes` (lasso
    /// move/delete, transform undo). The page-strip thumbnail key
    /// is `(pageId, page.updatedAt, pdfIndex)` — without the stamp
    /// those rewrites would keep serving the stale thumbnail.
    /// Caller owns the surrounding `context.save()`.
    @MainActor
    static func stampPage(pageId: UUID, context: ModelContext) {
        let descriptor = FetchDescriptor<Page>(
            predicate: #Predicate<Page> { $0.id == pageId }
        )
        (try? context.fetch(descriptor))?.first?.updatedAt = Date()
    }
}

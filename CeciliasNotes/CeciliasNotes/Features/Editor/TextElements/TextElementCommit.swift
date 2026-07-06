import CoreGraphics
import Foundation
import SwiftData

/// Centralised insert for V6 `PageElement(kind: .text) + TextContent`
/// created outside the editing flow — currently the AI "Summarize
/// this page" result sheet, which inserts its summary as an `.ai`-
/// sourced text element.
///
/// `TextElementsOverlayView` owns the *interactive* create path
/// (tap-to-place + immediate edit). That path bumps the overlay's
/// own `refreshTick` directly. This helper exists for the
/// non-interactive case: a caller that isn't the overlay needs the
/// overlay to re-fetch. It posts `.textElementsChanged`, which the
/// overlay observes — mirrors `StickyNoteCommit` + `.stickyNotesChanged`.
enum TextElementCommit {

    /// Insert a text element on `pageId` at the given normalised
    /// rect. Returns the inserted element, or `nil` on save failure.
    /// Posts `.textElementsChanged` so `TextElementsOverlayView`
    /// re-fetches and the new element appears without a tool switch.
    @discardableResult
    @MainActor
    static func create(
        text: String,
        source: TextSource,
        pageId: UUID,
        notebookId: UUID,
        normalizedRect: CGRect,
        size: TextSize = .body,
        context: ModelContext? = nil
    ) -> PageElement? {
        let context = context ?? StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let maxZ = existing.map(\.zIndex).max() ?? 0

        let element = PageElement(
            pageId:           pageId,
            notebookId:       notebookId,
            kind:             .text,
            normalizedX:      normalizedRect.origin.x,
            normalizedY:      normalizedRect.origin.y,
            normalizedWidth:  normalizedRect.width,
            normalizedHeight: normalizedRect.height,
            zIndex:           maxZ + 1
        )
        let content = TextContent(text: text, source: source, size: size)
        element.textContent = content
        context.insert(element)

        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[TextElementCommit] save failed on create: \(error)")
            #endif
            return nil
        }

        NotebookOriginRecorder.markNotebookModified(notebookId: notebookId, context: context)

        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        return element
    }
}

// MARK: - Notification

extension Notification.Name {
    /// Posted when a text element is created outside the overlay's
    /// own interactive path. `TextElementsOverlayView` observes this
    /// to re-fetch its element list.
    static let textElementsChanged = Notification.Name("textElementsChanged")
}

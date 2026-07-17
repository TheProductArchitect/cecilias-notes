import Foundation
import SwiftData

/// Centralised insert / soft-delete for V6
/// `PageElement(kind: .stickyNote) + StickyNoteContent`. Mirrors
/// `HighlightCommit` (Step 5.5) — keeps SwiftData mutation +
/// `.stickyNotesChanged` notification posting in one place so
/// callers (overlay, view-model, lasso paste, etc.) don't have to
/// re-derive the wiring.
enum StickyNoteCommit {

    /// Canonical key order — drives the colour picker's swatch
    /// layout and any "next colour" cycling. Kept here so the view
    /// + commit helper agree on a single source.
    static let paletteKeys: [String] = ["yellow", "pink", "blue", "green"]

    /// Default card dimensions in points. Small portrait card —
    /// quick-capture friendly. Resizable via the standard
    /// cursor-mode handles once Step 9 ships them for stickies.
    static let defaultCardSize = CGSize(width: 160, height: 120)

    // MARK: - Create

    /// Insert a fresh sticky element on the given page anchored at
    /// the supplied normalised position. The position becomes the
    /// card's *centre* — placement is the user's tap location and
    /// the card grows outward. Returns the inserted element so the
    /// caller can immediately mark it editing.
    @discardableResult
    @MainActor
    static func createSticky(
        atNormalizedCenter center: CGPoint,
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize,
        colorVariant: String = "yellow",
        context: ModelContext? = nil
    ) -> PageElement? {
        let context = context ?? StorageService.shared.context
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let normW = Double(defaultCardSize.width  / pageSize.width)
        let normH = Double(defaultCardSize.height / pageSize.height)

        // Clamp so the card stays fully inside the page even when
        // the user taps near an edge. Tap point lands at the card
        // centre, so we offset by half-card before clamping.
        let halfW = normW / 2
        let halfH = normH / 2
        let cx = max(halfW, min(1 - halfW, Double(center.x)))
        let cy = max(halfH, min(1 - halfH, Double(center.y)))
        let normX = cx - halfW
        let normY = cy - halfH

        // zIndex: top of the existing sticky stack on this page.
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let existing = (try? context.fetch(descriptor)) ?? []
        let maxZ = existing.filter { $0.kind == .stickyNote }
            .map(\.zIndex).max() ?? 0

        let element = PageElement(
            pageId:          pageId,
            notebookId:      notebookId,
            kind:            .stickyNote,
            normalizedX:     normX,
            normalizedY:     normY,
            normalizedWidth: normW,
            normalizedHeight: normH,
            zIndex:          maxZ + 1
        )
        let content = StickyNoteContent(
            text:         "",
            colorVariant: colorVariant
        )
        element.stickyNoteContent = content
        context.insert(element)

        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[StickyNote] save failed on create: \(error)")
            #endif
            return nil
        }

        NotificationCenter.default.post(
            name: .stickyNotesChanged, object: nil
        )
        return element
    }

    // MARK: - Soft-delete

    /// Soft-delete one sticky element by id. Posts
    /// `.stickyNotesChanged` so the annotation sheet + customise
    /// panel count refresh without polling.
    @MainActor
    static func softDelete(
        elementId: UUID,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == elementId }
        )
        guard let element = try? context.fetch(descriptor).first else { return }
        element.deletedAt = Date()
        element.updatedAt = Date()
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[StickyNote] softDelete SAVE FAILED elementId=\(elementId): \(error)")
            #endif
        }
        NotificationCenter.default.post(
            name: .stickyNotesChanged, object: nil
        )
    }
}

// `Notification.Name.stickyNotesChanged` is declared in
// `Core/Extensions/ElementChangeNotifications.swift` — shared with
// the Mac target, which posts it from trash restore.

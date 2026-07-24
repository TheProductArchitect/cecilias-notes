import Foundation
import SwiftData

/// Z-order ("layers") control for `PageElement`s.
///
/// Same-kind elements on a page render in `zIndex` order inside their
/// shared overlay (`PageElementOverlayFetch` sorts by `zIndex`), so
/// raising or lowering an element's `zIndex` relative to its same-kind
/// siblings is exactly what "bring to front" / "send to back" mean for
/// overlapping items — e.g. two stacked image screenshots. Cross-kind
/// stacking (an image vs a text element) is fixed by
/// `PageOverlaysContainer`'s ZStack order and is intentionally out of
/// scope here.
///
/// `nonisolated` so the pure decisions (`newZIndex`,
/// `refreshNotification`) are callable from the non-`@MainActor`
/// unit-test target under the project's default main-actor isolation;
/// `apply` opts back into `@MainActor` for its SwiftData work.
nonisolated enum PageElementOrdering {

    nonisolated enum Move: Equatable {
        case toFront
        case toBack

        var actionName: String {
            switch self {
            case .toFront: return "Bring to Front"
            case .toBack:  return "Send to Back"
            }
        }
    }

    /// The new `zIndex` that moves `target` in front of / behind every
    /// same-kind sibling — or `nil` when it is already there (a no-op,
    /// so the caller can skip the undo-registering write).
    ///
    /// `siblings` is `(id, zIndex)` for every same-kind element on the
    /// page, INCLUDING the target. Pure and view-independent so the
    /// decision is unit-testable without SwiftData.
    static func newZIndex(
        for target: UUID,
        move: Move,
        siblings: [(id: UUID, zIndex: Int)]
    ) -> Int? {
        let others = siblings.filter { $0.id != target }
        guard !others.isEmpty else { return nil }   // alone → nothing to reorder
        guard let current = siblings.first(where: { $0.id == target })?.zIndex else { return nil }
        switch move {
        case .toFront:
            let maxOther = others.map(\.zIndex).max()!
            return current > maxOther ? nil : maxOther + 1
        case .toBack:
            let minOther = others.map(\.zIndex).min()!
            return current < minOther ? nil : minOther - 1
        }
    }

    /// Overlay-refresh signal for a given element kind — the manual-
    /// fetch overlays reload on these (they don't use `@Query`). The
    /// `Notification.Name` statics are main-actor-isolated, so this is
    /// too; `apply` (also `@MainActor`) is its only caller.
    @MainActor
    static func refreshNotification(for kind: ElementKind) -> Notification.Name {
        switch kind {
        case .image:      return .mediaAttachmentsChanged
        case .shape:      return .shapeElementsChanged
        case .stickyNote: return .stickyNotesChanged
        case .text:       return .textElementsChanged
        case .audio:      return .audioElementsChanged
        case .pdfPage:    return .pdfPageElementsChanged
        default:          return .mediaAttachmentsChanged
        }
    }

    /// Fetch the target's same-kind siblings, compute the new `zIndex`,
    /// and commit it (undo-registered, saved, overlay refreshed). No-op
    /// when the element is already at the requested end.
    @MainActor
    static func apply(_ move: Move, to element: PageElement, context: ModelContext) {
        let pid = element.pageId
        let kind = element.kind
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let sameKind = ((try? context.fetch(descriptor)) ?? []).filter { $0.kind == kind }
        let siblings = sameKind.map { (id: $0.id, zIndex: $0.zIndex) }
        guard let newZ = newZIndex(for: element.id, move: move, siblings: siblings) else { return }
        LassoTransformUndo.withUndo(elementId: element.id, actionName: move.actionName) {
            element.zIndex   = newZ
            element.updatedAt = Date()
        }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Layers] apply \(move.actionName) save failed: \(error)")
            #endif
        }
        NotificationCenter.default.post(name: refreshNotification(for: kind), object: nil)
    }
}

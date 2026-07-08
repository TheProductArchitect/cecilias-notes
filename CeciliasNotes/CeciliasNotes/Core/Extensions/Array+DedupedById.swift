import Foundation

/// Models that stamp their last mutation. Lets duplicate-tolerant
/// list helpers keep the FRESHEST copy instead of an arbitrary one.
protocol UpdatedAtStamped {
    var updatedAt: Date { get }
}

extension Page: UpdatedAtStamped {}
extension Notebook: UpdatedAtStamped {}

extension Array where Element: Identifiable, Element.ID: Hashable {
    /// First-occurrence de-duplication by `id`, preserving order.
    ///
    /// iOS 26 SwiftUI's `ForEach` hard-crashes when two elements
    /// share an identifier (`NativeDictionary.swift: Fatal error:
    /// Duplicate values for key`). CloudKit echoes and cross-device
    /// races (two devices importing the same Inbox `.inkbook`
    /// before sync converges) can transiently leave SwiftData with
    /// duplicate primary keys — the store-side sweep
    /// (`StorageService.purgeDuplicateRows`) cleans them up within
    /// seconds, but any list that renders in that window must
    /// tolerate the duplicates or the app dies before the sweep
    /// runs. Every `ForEach` fed by a SwiftData fetch should pass
    /// through this (or an equivalent) first.
    ///
    /// `LibraryViewModel` / `EditorViewModel` carry their own
    /// private equivalents predating this shared helper.
    func dedupedById() -> [Element] {
        var seen = Set<Element.ID>()
        var result: [Element] = []
        result.reserveCapacity(count)
        for item in self where seen.insert(item.id).inserted {
            result.append(item)
        }
        return result
    }
}

extension Array where Element: Identifiable & UpdatedAtStamped, Element.ID: Hashable {
    /// De-duplication that keeps the NEWEST copy of each id (by
    /// `updatedAt`), preserving first-encounter order. First-wins
    /// dedupe on pages caused phantom "undo": when a stale duplicate
    /// row happened to be fetched first, a mid-session refresh handed
    /// the editor the OLD strokes and the user's latest ink visibly
    /// vanished. Newest-wins makes a duplicate window cosmetically
    /// invisible instead of destructive.
    func dedupedByIdNewestWins() -> [Element] {
        var newestById: [Element.ID: Element] = [:]
        var order: [Element.ID] = []
        for item in self {
            if let existing = newestById[item.id] {
                if item.updatedAt > existing.updatedAt {
                    newestById[item.id] = item
                }
            } else {
                newestById[item.id] = item
                order.append(item.id)
            }
        }
        return order.compactMap { newestById[$0] }
    }
}

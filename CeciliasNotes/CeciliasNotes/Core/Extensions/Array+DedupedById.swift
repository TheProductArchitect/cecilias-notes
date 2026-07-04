import Foundation

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

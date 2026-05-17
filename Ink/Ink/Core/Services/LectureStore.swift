import Foundation
import SwiftData

/// Static façade over the `LectureRecord` SwiftData entity. Phase
/// 5A+5C Step 2: this used to be a UserDefaults JSON store with a
/// sibling `struct LectureRecord`; the struct moved to a real
/// `@Model class LectureRecord` (see `Core/Models/LectureRecord.swift`)
/// and the static API here now reads/writes through SwiftData via
/// `StorageService.shared.context`.
///
/// The façade survives the rewrite because every caller in the editor
/// — `LectureRecorder`, `LectureBlockView`, `IntelligenceService`,
/// `SearchIndexService`, `StorageService.purgeNotebookFiles` —
/// already expects this enum-shaped API. Routing through it keeps
/// the migration to one place and isolates SwiftData-context plumbing
/// from the call sites.
///
/// `.lectureRecordUpdated` is still posted from `save(_:)` so
/// `LectureBlockView` re-fetches on every external mutation without
/// any caller-side change.
///
/// **Why a static façade over a ModelActor:** writes are cheap, file
/// I/O is the slow part and already runs off-main via
/// `Task.detached` inside `LectureRecorder.refineTranscript` and
/// friends. Adding a dedicated actor would buy ~150 lines of
/// boilerplate for no observable behaviour change. See the saved
/// project memory for the off-main-actor decision rationale.
enum LectureStore {

    // MARK: - Read

    static func records(for pageId: UUID) -> [LectureRecord] {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<LectureRecord>(
            predicate: #Predicate { $0.pageId == pageId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    /// Alias of `records(for:)` for parity with other side-channel
    /// stores that surface both spellings.
    static func allActiveRecords(for pageId: UUID) -> [LectureRecord] {
        records(for: pageId)
    }

    static func record(id: UUID, pageId: UUID) -> LectureRecord? {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<LectureRecord>(
            predicate: #Predicate {
                $0.id == id && $0.pageId == pageId && $0.deletedAt == nil
            }
        )
        return try? context.fetch(descriptor).first
    }

    /// Every active record across every page. Used by
    /// `SearchIndexService` when it walks lecture transcripts, and by
    /// Pass B's summary-regeneration sweep.
    static func allActiveRecords() -> [LectureRecord] {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<LectureRecord>(
            predicate: #Predicate { $0.deletedAt == nil }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Write

    /// Insert or update a record. If `record` is already a managed
    /// object (fetched via the SwiftData context), property mutations
    /// have already landed and `save()` only flushes them. For a
    /// freshly-constructed record (e.g. from `LectureRecorder.stop`),
    /// this inserts into the context first.
    ///
    /// Always posts `.lectureRecordUpdated` so observers see the new
    /// snapshot — keeps `LectureBlockView`'s onReceive contract
    /// identical to the UserDefaults era.
    static func save(_ record: LectureRecord) {
        let context = StorageService.shared.context
        // An `insert` of an already-managed object is a no-op, so
        // calling it when `modelContext` is nil is the cheapest
        // "insert or attach" check available.
        if record.modelContext == nil {
            context.insert(record)
        }
        record.updatedAt = Date()
        try? context.save()
        NotificationCenter.default.post(
            name: .lectureRecordUpdated,
            object: nil,
            userInfo: ["recordId": record.id]
        )
    }

    static func softDelete(id: UUID, pageId: UUID) {
        guard let record = record(id: id, pageId: pageId) else { return }
        record.deletedAt = Date()
        record.updatedAt = Date()
        try? StorageService.shared.context.save()
    }

    /// Hard-delete every record for the given pages AND remove the
    /// underlying audio files from disk. Called by
    /// `StorageService.purgeNotebookFiles` on reaper purge.
    static func forget(pageIds: [UUID]) {
        guard !pageIds.isEmpty else { return }
        let context = StorageService.shared.context
        let pageIdSet = Set(pageIds)
        let descriptor = FetchDescriptor<LectureRecord>(
            predicate: #Predicate { pageIdSet.contains($0.pageId) }
        )
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        let records = (try? context.fetch(descriptor)) ?? []
        for record in records {
            let url = docs.appendingPathComponent(record.audioRelativePath)
            try? FileManager.default.removeItem(at: url)
            context.delete(record)
        }
        try? context.save()
    }
}

// MARK: - Change notifications

extension Notification.Name {
    /// Posted whenever a single `LectureRecord` is mutated via
    /// `LectureStore.save`. `userInfo["recordId"]` carries the
    /// record's `UUID`. `LectureBlockView` listens for this so the
    /// async `generateLectureSummary` completion swaps
    /// "summarising…" for the summary content without a user-driven
    /// refresh.
    static let lectureRecordUpdated = Notification.Name("lectureRecordUpdated")
}

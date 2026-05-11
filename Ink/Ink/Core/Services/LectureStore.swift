import Foundation

/// Persistent record of a long-form lecture recording — audio file
/// path, accumulated transcript, duration, soft-delete stamp. Pass B
/// adds `summary` and `summaryBullets` as additive Codable fields
/// with default values, so any record serialised before Pass B
/// landed deserialises cleanly (the synthesised decoder treats
/// missing keys as the default).
struct LectureRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let pageId: UUID
    var title: String
    /// Audio file path relative to the app's Documents directory —
    /// matches the side-channel pattern used by audio annotations.
    /// Resolved at read-time via `FileManager.default.urls(for:in:)`
    /// so the absolute path can change between launches (it doesn't
    /// today, but the relative-path contract future-proofs it).
    var audioRelativePath: String
    var transcript: String
    var durationSeconds: Double
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    // MARK: Pass B — AI summary fields
    //
    // `nil` / empty until `IntelligenceService.generateLectureSummary`
    // completes. On iOS 18 (or when `IntelligenceService.canRun` is
    // false) these stay at their defaults forever; the editor's
    // `LectureBlockView` reads `hasSummary` and omits the summary
    // section entirely when it returns false. Generation runs once
    // per record — there is no auto-regeneration path.
    var summary: String? = nil
    var summaryBullets: [String] = []

    /// True when both summary fields are populated. Single source of
    /// truth for the "show summary" gate in `LectureBlockView`.
    var hasSummary: Bool { summary != nil && !summaryBullets.isEmpty }
}

/// Side-channel store for lectures. Mirrors `StickyNoteStore` /
/// `PDFBackingStore` exactly — UserDefaults JSON dictionary keyed
/// by `pageId.uuidString`, single source of truth for lecture
/// records. **No SwiftData entity** — the V3 schema can't take new
/// model types without crashing, so every new persistent annotation
/// kind in this codebase rides on a side-channel store.
///
/// Records are soft-deleted (stamp `deletedAt`) so an undo path
/// could restore them without re-keying. `forget(pageIds:)` is the
/// hard-delete entry, called by `StorageService.purgeNotebookFiles`
/// when a notebook is reaper-purged.
enum LectureStore {

    private static let storageKey = "lecture.store.v1"

    // MARK: Read

    static func records(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> [LectureRecord] {
        readMap(defaults: defaults)[pageId.uuidString]?
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// Alias for `records(for:)` named to match the
    /// `allActiveRecords()` (no-arg) convention used elsewhere in the
    /// store. Both return only non-soft-deleted records.
    static func allActiveRecords(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> [LectureRecord] {
        records(for: pageId, defaults: defaults)
    }

    static func record(
        id: UUID,
        pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> LectureRecord? {
        readMap(defaults: defaults)[pageId.uuidString]?
            .first { $0.id == id && $0.deletedAt == nil }
    }

    /// All active records across all pages — used by the search
    /// index when it needs to walk every lecture transcript, and by
    /// Pass B's summary regeneration sweep.
    static func allActiveRecords(
        defaults: UserDefaults = .standard
    ) -> [LectureRecord] {
        readMap(defaults: defaults).values.flatMap { $0 }
            .filter { $0.deletedAt == nil }
    }

    // MARK: Write

    /// Insert or update a record. Keyed by `record.id`; replaces
    /// any existing entry with the same id under the same pageId.
    static func save(
        _ record: LectureRecord,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        var arr = map[record.pageId.uuidString] ?? []
        if let idx = arr.firstIndex(where: { $0.id == record.id }) {
            arr[idx] = record
        } else {
            arr.append(record)
        }
        map[record.pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
        // Fire after the write completes so observers reading from
        // the store inside the notification handler see the new
        // record, not the previous one.
        NotificationCenter.default.post(
            name: .lectureRecordUpdated,
            object: nil,
            userInfo: ["recordId": record.id]
        )
    }

    static func softDelete(
        id: UUID,
        pageId: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        guard var arr = map[pageId.uuidString],
              let idx = arr.firstIndex(where: { $0.id == id })
        else { return }
        arr[idx].deletedAt = Date()
        arr[idx].updatedAt = Date()
        map[pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
    }

    /// Hard-delete every record for the given pages AND remove the
    /// underlying audio files from disk. Called by
    /// `StorageService.purgeNotebookFiles` on reaper purge — keeps
    /// the UserDefaults dictionary tight and prevents abandoned
    /// audio from accumulating in Documents/.
    static func forget(
        pageIds: [UUID],
        defaults: UserDefaults = .standard
    ) {
        guard !pageIds.isEmpty else { return }
        var map = readMap(defaults: defaults)

        // Collect the audio paths to remove before we drop the
        // records.
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
        for pid in pageIds {
            if let arr = map[pid.uuidString] {
                for record in arr {
                    let url = docs.appendingPathComponent(record.audioRelativePath)
                    try? FileManager.default.removeItem(at: url)
                }
            }
            map.removeValue(forKey: pid.uuidString)
        }
        writeMap(map, defaults: defaults)
    }

    // MARK: Internals

    private static func readMap(
        defaults: UserDefaults
    ) -> [String: [LectureRecord]] {
        guard let raw  = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode(
                  [String: [LectureRecord]].self, from: data
              )
        else { return [:] }
        return map
    }

    private static func writeMap(
        _ map: [String: [LectureRecord]],
        defaults: UserDefaults
    ) {
        let compact = map.filter { !$0.value.isEmpty }
        if compact.isEmpty {
            defaults.removeObject(forKey: storageKey)
            return
        }
        guard let data = try? JSONEncoder().encode(compact),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: storageKey)
    }
}

// MARK: - Change notifications

extension Notification.Name {
    /// Posted whenever a single `LectureRecord` is replaced via
    /// `LectureStore.save`. `userInfo["recordId"]` carries the
    /// record's `UUID`. `LectureBlockView` listens for this so the
    /// async `generateLectureSummary` completion swaps
    /// "summarising…" for the summary content without a user-driven
    /// refresh.
    static let lectureRecordUpdated = Notification.Name("lectureRecordUpdated")
}

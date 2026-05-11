/// PDFTextAnnotationStore.swift
/// Cecilia's Notes
///
/// Side-channel store for highlight / underline / strikethrough
/// annotations on PDF-backed pages. Mirrors `StickyNoteStore`
/// exactly — `UserDefaults.standard`, JSON-encoded dictionary keyed
/// by `pageId.uuidString`, soft-delete via `deletedAt`, hard-delete
/// via `forget(pageIds:)` from the reaper.
///
/// Why a side-channel rather than a SwiftData model: same rationale
/// as the rest of the v4 schema — adding a new entity type forces a
/// version bump with structurally-distinct Swift types. See
/// `InkSchemas.swift` and `ARCHITECTURE.md`.

import Foundation

enum PDFTextAnnotationStore {

    private static let storageKey = "pdf.text.annotations.v1"

    // MARK: - Read

    /// Active (non-deleted) records for a page, sorted by createdAt.
    /// Returns `[]` for pages with no annotations.
    static func records(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> [PDFTextAnnotationRecord] {
        readMap(defaults: defaults)[pageId.uuidString]?
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// Every active record across every page. Used by `ExportService`
    /// when stamping annotations into the export PDF and by the
    /// customise panel's count row.
    static func allActiveRecords(
        defaults: UserDefaults = .standard
    ) -> [PDFTextAnnotationRecord] {
        readMap(defaults: defaults).values.flatMap { $0 }
            .filter { $0.deletedAt == nil }
    }

    // MARK: - Mutate

    /// Insert or replace a record by `id`. Saving the same id twice
    /// overwrites the previous entry (used by the type-toggle and
    /// undo-restore paths).
    static func save(
        _ record: PDFTextAnnotationRecord,
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
    }

    /// Soft-delete — stamps `deletedAt`, leaves the record in the
    /// store so an undo path could restore it without re-keying.
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

    /// Restore a previously soft-deleted record by clearing
    /// `deletedAt`. Used by the editor's undo path.
    static func restore(
        id: UUID,
        pageId: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        guard var arr = map[pageId.uuidString],
              let idx = arr.firstIndex(where: { $0.id == id })
        else { return }
        arr[idx].deletedAt = nil
        arr[idx].updatedAt = Date()
        map[pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
    }

    /// Hard-delete every record for the given pages. Called from
    /// `StorageService.purgeNotebookFiles` when a notebook is
    /// reaper-purged. Keeps the on-disk dictionary tight.
    static func forget(
        pageIds: [UUID],
        defaults: UserDefaults = .standard
    ) {
        guard !pageIds.isEmpty else { return }
        var map = readMap(defaults: defaults)
        for id in pageIds { map.removeValue(forKey: id.uuidString) }
        writeMap(map, defaults: defaults)
    }

    // MARK: - Internals

    private static func readMap(
        defaults: UserDefaults
    ) -> [String: [PDFTextAnnotationRecord]] {
        guard let raw  = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode(
                  [String: [PDFTextAnnotationRecord]].self, from: data
              )
        else { return [:] }
        return map
    }

    private static func writeMap(
        _ map: [String: [PDFTextAnnotationRecord]],
        defaults: UserDefaults
    ) {
        // Prune empty page entries so the dictionary doesn't
        // accumulate `pageId: []` keys over time.
        let compact = map.filter { !$0.value.isEmpty }
        if compact.isEmpty {
            defaults.removeObject(forKey: storageKey)
            // Post the change notification anyway so observers update.
            NotificationCenter.default.post(name: .pdfTextAnnotationsChanged, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(compact),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: storageKey)
        // Reactive overlay rendering: the editor canvas observes this
        // notification and triggers a `setNeedsDisplay` on the
        // overlay layer so soft-deletes / new records appear without
        // a page reload.
        NotificationCenter.default.post(name: .pdfTextAnnotationsChanged, object: nil)
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted whenever the on-disk store mutates. Editor overlays
    /// listen for this to re-paint without rebuilding the page.
    static let pdfTextAnnotationsChanged = Notification.Name("pdfTextAnnotationsChanged")
}

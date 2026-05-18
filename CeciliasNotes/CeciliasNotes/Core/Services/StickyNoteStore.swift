import Foundation

/// On-device storage for sticky notes — typed comments anchored to a
/// specific point on a notebook page.
///
/// Side-channel pattern, matching `PDFBackingStore` /
/// `NotebookPreferencesStore`. The codebase's V3 SwiftData schema
/// can't take new entity types in place (see `CeciliasNotesSchemas.swift`), so
/// new annotation kinds live in UserDefaults JSON. Functionally
/// equivalent to a `@Model` class — same soft-delete semantics, same
/// per-page lookup — but no schema bump.
///
/// Storage shape: one global JSON dictionary keyed by `pageId`
/// (uuidString) holding an array of `StickyNoteRecord`. Reads filter
/// out `deletedAt != nil`; writes update the array and re-serialise.
///
/// **Nothing leaves the device.** Sticky notes round-trip through
/// UserDefaults only; export embeds them as `PDFAnnotation.freeText`
/// inside the user's local PDF.
enum StickyNoteStore {

    private static let storageKey = "app.stickyNotes.v1"

    // MARK: Read

    /// Active (non-deleted) sticky notes for a page, sorted by
    /// `createdAt` so the on-page render order is stable across
    /// launches.
    static func notes(
        for pageId: UUID,
        defaults: UserDefaults = .standard
    ) -> [StickyNoteRecord] {
        readMap(defaults: defaults)[pageId.uuidString]?
            .filter { $0.deletedAt == nil }
            .sorted { $0.createdAt < $1.createdAt } ?? []
    }

    /// Every active sticky note across every page, used by the
    /// customise panel's annotation count row and the export
    /// pipeline. The store knows nothing about which notebook a
    /// page belongs to — callers map pageIds → notebook themselves.
    static func allActiveNotes(
        defaults: UserDefaults = .standard
    ) -> [StickyNoteRecord] {
        readMap(defaults: defaults).values.flatMap { $0 }
            .filter { $0.deletedAt == nil }
    }

    // MARK: Mutate

    /// Append a fresh sticky note to `pageId`. Returns the inserted
    /// record so callers can immediately open the popover editor for
    /// it.
    @discardableResult
    static func add(
        pageId: UUID,
        normalizedX: Double,
        normalizedY: Double,
        defaults: UserDefaults = .standard
    ) -> StickyNoteRecord {
        let record = StickyNoteRecord(
            id:           UUID(),
            pageId:       pageId,
            normalizedX:  normalizedX,
            normalizedY:  normalizedY,
            body:         "",
            createdAt:    Date(),
            updatedAt:    Date(),
            deletedAt:    nil
        )
        var map = readMap(defaults: defaults)
        var arr = map[pageId.uuidString] ?? []
        arr.append(record)
        map[pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
        return record
    }

    static func updateBody(
        id: UUID,
        pageId: UUID,
        body: String,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(defaults: defaults)
        guard var arr = map[pageId.uuidString],
              let idx = arr.firstIndex(where: { $0.id == id })
        else { return }
        arr[idx].body = body
        arr[idx].updatedAt = Date()
        map[pageId.uuidString] = arr
        writeMap(map, defaults: defaults)
    }

    /// Soft-delete — stamps `deletedAt`, leaves the record in the
    /// store so an undo path could restore it without re-keying.
    /// Matches the soft-delete pattern every model in this codebase
    /// follows.
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

    /// Hard delete every record for the given page ids — used by the
    /// reaper purge path when a notebook is permanently removed.
    static func forget(
        pageIds: [UUID],
        defaults: UserDefaults = .standard
    ) {
        guard !pageIds.isEmpty else { return }
        var map = readMap(defaults: defaults)
        for id in pageIds { map.removeValue(forKey: id.uuidString) }
        writeMap(map, defaults: defaults)
    }

    // MARK: Internals

    private static func readMap(
        defaults: UserDefaults
    ) -> [String: [StickyNoteRecord]] {
        guard let raw  = defaults.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode(
                  [String: [StickyNoteRecord]].self, from: data
              )
        else { return [:] }
        return map
    }

    private static func writeMap(
        _ map: [String: [StickyNoteRecord]],
        defaults: UserDefaults
    ) {
        // Prune fully-empty page entries so the dictionary doesn't
        // accumulate `pageId: []` keys.
        let compact = map.filter { !$0.value.isEmpty }
        if compact.isEmpty {
            defaults.removeObject(forKey: storageKey)
            NotificationCenter.default.post(name: .stickyNotesChanged, object: nil)
            return
        }
        guard let data = try? JSONEncoder().encode(compact),
              let str  = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(str, forKey: storageKey)
        // Mirrors `pdfTextAnnotationsChanged` — observers (annotation
        // list sheet, customise panel count row) refresh on this
        // post without having to poll the store.
        NotificationCenter.default.post(name: .stickyNotesChanged, object: nil)
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted whenever `StickyNoteStore` mutates. Parallel to
    /// `.pdfTextAnnotationsChanged` so any view watching one surface
    /// can subscribe to both for full annotation coverage.
    static let stickyNotesChanged = Notification.Name("stickyNotesChanged")
}

// MARK: - StickyNoteRecord

/// Codable wire format for `StickyNoteStore`. Mirrors the spec's
/// schema (id / pageId / normalised position / body / timestamps /
/// soft-delete) but lives in JSON instead of SwiftData per the
/// codebase's side-channel pattern.
extension CGFloat {
    /// Clamp to the unit interval. Used by sticky-note placement so
    /// a tap that lands slightly outside the page bounds (drag bias,
    /// rounding) still produces a valid 0–1 position.
    var clamped01: CGFloat { Swift.min(1, Swift.max(0, self)) }
}

struct StickyNoteRecord: Codable, Sendable, Identifiable, Hashable {
    let id: UUID
    let pageId: UUID
    /// Normalised 0–1 in page coordinate space. Pinned to the page
    /// — reordering changes the page's `pageNumber` but not the
    /// position of the note on that page.
    var normalizedX: Double
    var normalizedY: Double
    var body: String
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
}

import Foundation

/// Small UserDefaults-backed tracker for "which notebooks did the user
/// most recently open." Used by the Library home "🕐 recently opened"
/// strip via `StorageService.fetchRecentNotebooks(limit:)`.
///
/// Storage layout: a single JSON blob under
/// `app.recents.notebooks` keyed `id` → `timestamp`. The dictionary form
/// makes update-on-open an O(1) write, regardless of history length, and
/// keeps the on-disk size bounded by `maxEntries`.
///
/// Why not a SwiftData column on `Notebook`? — adding a property to a
/// pinned schema version trips SwiftData's "Cannot use staged migration
/// with an unknown model version" check. The codebase comment in
/// `CeciliasNotesSchemas.swift` documents the failure mode in detail. Until a
/// future schema bump introduces enum-scoped model types, side-channel
/// per-notebook metadata lives here.
enum RecentNotebooksTracker {

    private static let key = "app.recents.notebooks"
    /// Bound the dictionary so the JSON blob stays small even for
    /// libraries with thousands of notebooks. The Library only needs
    /// the top six; keeping ~50 gives us headroom for deleted-notebook
    /// drop-outs without re-promoting stale entries.
    private static let maxEntries = 50

    // MARK: Read

    /// All tracked notebook ids, newest-opened first. Defaults storage
    /// is intentionally swallowed on decode failure — the worst case is
    /// the strip starts empty and rebuilds as the user opens notebooks.
    static func recentIdsNewestFirst(
        defaults: UserDefaults = .standard
    ) -> [UUID] {
        let map = readMap(from: defaults)
        return map
            .sorted { $0.value > $1.value }
            .compactMap { UUID(uuidString: $0.key) }
    }

    /// Last-opened timestamp for a single notebook, or `nil` if it's
    /// never been opened (or has been forgotten).
    static func lastOpened(
        _ id: UUID,
        defaults: UserDefaults = .standard
    ) -> Date? {
        let map = readMap(from: defaults)
        guard let interval = map[id.uuidString] else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    // MARK: Write

    static func markOpened(
        _ id: UUID,
        at date: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(from: defaults)
        map[id.uuidString] = date.timeIntervalSince1970

        // Trim oldest entries beyond `maxEntries`. Sort once, slice once.
        if map.count > maxEntries {
            let kept = map
                .sorted { $0.value > $1.value }
                .prefix(maxEntries)
            map = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }

        writeMap(map, to: defaults)
    }

    /// Drop a notebook from the tracker. Called by storage when a
    /// notebook is hard-deleted so it doesn't haunt the strip if it
    /// somehow comes back via undelete with the same id.
    static func forget(
        _ id: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(from: defaults)
        guard map.removeValue(forKey: id.uuidString) != nil else { return }
        writeMap(map, to: defaults)
    }

    // MARK: Private

    private static func readMap(from defaults: UserDefaults) -> [String: TimeInterval] {
        guard let raw  = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode([String: TimeInterval].self, from: data)
        else { return [:] }
        return map
    }

    private static func writeMap(_ map: [String: TimeInterval], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: key)
    }
}

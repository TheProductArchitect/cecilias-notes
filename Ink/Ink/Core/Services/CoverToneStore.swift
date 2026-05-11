import Foundation

/// UserDefaults-backed side channel for `Notebook.coverTone`.
///
/// Why not a SwiftData column on `Notebook`?
/// Adding a property to a pinned schema version trips SwiftData's
/// "Cannot use staged migration with an unknown model version" check —
/// we hit this exact crash earlier in the project (commit 78b7942) and
/// resolved an analogous case (recent notebooks) by side-channeling the
/// data to UserDefaults instead. Until a future schema bump introduces
/// enum-scoped V4 model types, every per-notebook field that didn't
/// ship in V3 lives here.
///
/// Storage layout: a single JSON dictionary under
/// `app.notebooks.coverTone` keyed `id.uuidString → tone.rawValue`.
/// Notebooks without an entry resolve to `.parchment` via the accessor
/// on `Notebook` — so existing user data needs no migration step.
enum CoverToneStore {

    private static let key = "app.notebooks.coverTone"

    // MARK: Read

    static func tone(
        for id: UUID,
        defaults: UserDefaults = .standard
    ) -> NotebookCoverTone {
        let map = readMap(from: defaults)
        let raw = map[id.uuidString] ?? ""

        if let tone = NotebookCoverTone(rawValue: raw) {
            return tone
        }

        // Legacy / unrecognised raw value migration. The Phase D
        // redesign locked the palette to the 8 desaturated tones; if
        // an older build wrote a saturated string ("pink", "teal"…)
        // we map to the nearest neighbour. Any unknown string falls
        // through to `.parchment`. The mapped value is written back
        // so subsequent reads bypass this branch entirely.
        let migrated = mapLegacy(raw)
        if !raw.isEmpty {
            setTone(migrated, for: id, defaults: defaults)
        }
        return migrated
    }

    private static func mapLegacy(_ raw: String) -> NotebookCoverTone {
        switch raw.lowercased() {
        case "pink", "blush":                       return .parchment
        case "orange", "terracotta":                return .dusk
        case "teal", "sage", "green":               return .moss
        case "lavender", "lilac", "purple":         return .ash
        case "slate":                               return .coal
        case "navy", "indigo":                      return .midnight
        default:                                    return .parchment
        }
    }

    // MARK: Write

    static func setTone(
        _ tone: NotebookCoverTone,
        for id: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(from: defaults)
        map[id.uuidString] = tone.rawValue
        writeMap(map, to: defaults)
    }

    /// Drop a notebook's tone entry. Called when the notebook is
    /// permanently deleted so the dictionary doesn't accumulate
    /// orphaned ids.
    static func forget(
        _ id: UUID,
        defaults: UserDefaults = .standard
    ) {
        var map = readMap(from: defaults)
        guard map.removeValue(forKey: id.uuidString) != nil else { return }
        writeMap(map, to: defaults)
    }

    // MARK: Bulk read for the assigner

    /// All tones currently set, keyed by notebook id. Used by
    /// `CoverToneAssigner` to compute "what's already in this subject"
    /// without touching SwiftData.
    static func allTones(
        defaults: UserDefaults = .standard
    ) -> [UUID: NotebookCoverTone] {
        let raw = readMap(from: defaults)
        var out: [UUID: NotebookCoverTone] = [:]
        for (k, v) in raw {
            if let id = UUID(uuidString: k),
               let tone = NotebookCoverTone(rawValue: v) {
                out[id] = tone
            }
        }
        return out
    }

    // MARK: Private

    private static func readMap(from defaults: UserDefaults) -> [String: String] {
        guard let raw = defaults.string(forKey: key),
              let data = raw.data(using: .utf8),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    private static func writeMap(_ map: [String: String], to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(map),
              let json = String(data: data, encoding: .utf8)
        else { return }
        defaults.set(json, forKey: key)
    }
}

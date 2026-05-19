import Foundation

/// Static-method enum like the other side-channel stores
/// (`CoverToneStore`, `RecentNotebooksTracker`). Non-isolated —
/// `Notebook`'s computed accessors are nonisolated and need to call
/// the store synchronously from any context.
///
/// Storage layout: one `Data` value per notebook UUID under
/// `app.notebooks.preferences.v1.<uuid>`. The blob is a JSON object
/// keyed by `String` field names; `JSONSerialization` is used
/// directly so no `Codable` conformance is required on the struct
/// (avoiding Swift 6 global-actor inference on synthesised witnesses).
enum NotebookPreferencesStore {

    nonisolated private static let storagePrefix = "app.notebooks.preferences.v1"
    nonisolated private static let legacyAutoAddPagesKey = "app.notebooks.autoAddPages"

    // MARK: Read

    nonisolated static func preferences(
        for notebookId: UUID,
        defaults: UserDefaults = .standard
    ) -> NotebookPreferences {
        if let data = defaults.data(forKey: key(for: notebookId)),
           let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool] {
            return NotebookPreferences(
                autoAddPagesOnScroll: dict["autoAddPagesOnScroll"] ?? true,
                autoHideHeader:       dict["autoHideHeader"]       ?? true
            )
        }

        // Legacy migration. The old `AutoAddPagesStore` stored a single
        // JSON dictionary `[uuidString: Bool]` under one global key.
        if let migrated = migrateFromLegacyAutoAddPages(for: notebookId, defaults: defaults) {
            setPreferences(migrated, for: notebookId, defaults: defaults)
            return migrated
        }

        return NotebookPreferences()
    }

    // MARK: Write

    nonisolated static func setPreferences(
        _ prefs: NotebookPreferences,
        for notebookId: UUID,
        defaults: UserDefaults = .standard
    ) {
        // Defaults aren't persisted — when a notebook's prefs match
        // `NotebookPreferences()` the entry is deleted.
        if prefs.autoAddPagesOnScroll == true && prefs.autoHideHeader == true {
            defaults.removeObject(forKey: key(for: notebookId))
            removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
            return
        }
        let dict: [String: Bool] = [
            "autoAddPagesOnScroll": prefs.autoAddPagesOnScroll,
            "autoHideHeader":       prefs.autoHideHeader
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            defaults.set(data, forKey: key(for: notebookId))
        }
        removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
    }

    /// Drop a notebook's preferences. Called when the notebook is
    /// permanently deleted so orphaned entries don't accumulate.
    nonisolated static func forget(
        _ notebookId: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(for: notebookId))
        removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
    }

    // MARK: Legacy migration

    nonisolated private static func migrateFromLegacyAutoAddPages(
        for notebookId: UUID,
        defaults: UserDefaults
    ) -> NotebookPreferences? {
        guard let legacyMap = readLegacyAutoAddMap(defaults: defaults),
              let value = legacyMap[notebookId.uuidString]
        else { return nil }
        return NotebookPreferences(autoAddPagesOnScroll: value, autoHideHeader: true)
    }

    nonisolated private static func readLegacyAutoAddMap(defaults: UserDefaults) -> [String: Bool]? {
        guard let raw  = defaults.string(forKey: legacyAutoAddPagesKey),
              let data = raw.data(using: .utf8),
              let map  = (try? JSONSerialization.jsonObject(with: data)) as? [String: Bool]
        else { return nil }
        return map
    }

    nonisolated private static func removeLegacyAutoAddEntry(
        for notebookId: UUID,
        defaults: UserDefaults
    ) {
        guard var map = readLegacyAutoAddMap(defaults: defaults) else { return }
        guard map.removeValue(forKey: notebookId.uuidString) != nil else { return }
        if map.isEmpty {
            defaults.removeObject(forKey: legacyAutoAddPagesKey)
            return
        }
        if let data = try? JSONSerialization.data(withJSONObject: map) {
            defaults.set(data, forKey: legacyAutoAddPagesKey)
        }
    }

    // MARK: Helpers

    nonisolated private static func key(for notebookId: UUID) -> String {
        "\(storagePrefix).\(notebookId.uuidString)"
    }
}

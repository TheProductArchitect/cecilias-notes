import Foundation

/// Bag of per-notebook preferences. Replaces the standalone
/// `AutoAddPagesStore` and consolidates future per-notebook flags
/// (auto-hide header today; could absorb cover-tone / recents in a
/// later refactor).
///
/// Persistence: one JSON-encoded `NotebookPreferences` blob per
/// notebook UUID under the key prefix `app.notebooks.preferences.v1`.
/// Defaults aren't persisted — when prefs match `NotebookPreferences()`
/// the entry is removed so the dictionary stays small for libraries
/// where most notebooks use defaults.
struct NotebookPreferences: Codable, Equatable {
    var autoAddPagesOnScroll: Bool = true
    var autoHideHeader:       Bool = true
}

/// Static-method enum like the other side-channel stores
/// (`CoverToneStore`, `RecentNotebooksTracker`). Non-isolated —
/// `Notebook`'s computed accessors are nonisolated and need to call
/// the store synchronously from any context.
enum NotebookPreferencesStore {

    private static let storagePrefix = "app.notebooks.preferences.v1"
    private static let legacyAutoAddPagesKey = "app.notebooks.autoAddPages"

    // MARK: Read

    static func preferences(
        for notebookId: UUID,
        defaults: UserDefaults = .standard
    ) -> NotebookPreferences {
        if let data = defaults.data(forKey: key(for: notebookId)),
           let prefs = try? JSONDecoder().decode(NotebookPreferences.self, from: data) {
            return prefs
        }

        // Legacy migration. The old `AutoAddPagesStore` stored a single
        // JSON dictionary `[uuidString: Bool]` under one global key.
        // If this notebook has an entry there, lift its value into the
        // new per-notebook blob and continue. Subsequent reads bypass
        // this branch.
        if let migrated = migrateFromLegacyAutoAddPages(for: notebookId, defaults: defaults) {
            setPreferences(migrated, for: notebookId, defaults: defaults)
            return migrated
        }

        return NotebookPreferences()
    }

    // MARK: Write

    static func setPreferences(
        _ prefs: NotebookPreferences,
        for notebookId: UUID,
        defaults: UserDefaults = .standard
    ) {
        // Defaults aren't persisted — when a notebook's prefs match
        // `NotebookPreferences()` the entry is deleted so the
        // dictionary stays small for libraries where most notebooks
        // never customise.
        if prefs == NotebookPreferences() {
            defaults.removeObject(forKey: key(for: notebookId))
            removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
            return
        }

        guard let data = try? JSONEncoder().encode(prefs) else { return }
        defaults.set(data, forKey: key(for: notebookId))
        removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
    }

    /// Drop a notebook's preferences. Called when the notebook is
    /// permanently deleted so orphaned entries don't accumulate.
    static func forget(
        _ notebookId: UUID,
        defaults: UserDefaults = .standard
    ) {
        defaults.removeObject(forKey: key(for: notebookId))
        removeLegacyAutoAddEntry(for: notebookId, defaults: defaults)
    }

    // MARK: Legacy migration

    private static func migrateFromLegacyAutoAddPages(
        for notebookId: UUID,
        defaults: UserDefaults
    ) -> NotebookPreferences? {
        guard let legacyMap = readLegacyAutoAddMap(defaults: defaults),
              let value = legacyMap[notebookId.uuidString]
        else { return nil }
        var prefs = NotebookPreferences()
        prefs.autoAddPagesOnScroll = value
        return prefs
    }

    private static func readLegacyAutoAddMap(defaults: UserDefaults) -> [String: Bool]? {
        guard let raw  = defaults.string(forKey: legacyAutoAddPagesKey),
              let data = raw.data(using: .utf8),
              let map  = try? JSONDecoder().decode([String: Bool].self, from: data)
        else { return nil }
        return map
    }

    private static func removeLegacyAutoAddEntry(
        for notebookId: UUID,
        defaults: UserDefaults
    ) {
        guard var map = readLegacyAutoAddMap(defaults: defaults) else { return }
        guard map.removeValue(forKey: notebookId.uuidString) != nil else { return }
        if map.isEmpty {
            defaults.removeObject(forKey: legacyAutoAddPagesKey)
            return
        }
        if let data = try? JSONEncoder().encode(map),
           let json = String(data: data, encoding: .utf8) {
            defaults.set(json, forKey: legacyAutoAddPagesKey)
        }
    }

    // MARK: Helpers

    private static func key(for notebookId: UUID) -> String {
        "\(storagePrefix).\(notebookId.uuidString)"
    }
}

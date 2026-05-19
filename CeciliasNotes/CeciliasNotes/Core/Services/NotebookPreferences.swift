import Foundation

/// Bag of per-notebook preferences persisted via `NotebookPreferencesStore`.
struct NotebookPreferences: Sendable {
    var autoAddPagesOnScroll: Bool = true
    var autoHideHeader:       Bool = true
}

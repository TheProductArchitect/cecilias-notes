import Foundation

/// Bag of per-notebook preferences persisted via `NotebookPreferencesStore`.
///
/// Explicitly `nonisolated`: the project's default actor isolation is
/// `MainActor`, which would otherwise make this struct (and its
/// initialiser) `@MainActor`-isolated — but `NotebookPreferencesStore`'s
/// accessors are `nonisolated` and construct it off the main actor.
nonisolated struct NotebookPreferences: Sendable {
    var autoAddPagesOnScroll: Bool = true
    var autoHideHeader:       Bool = true
}

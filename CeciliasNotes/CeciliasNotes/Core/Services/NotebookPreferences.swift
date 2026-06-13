import Foundation

/// Bag of per-notebook preferences persisted via `NotebookPreferencesStore`.
///
/// Explicitly `nonisolated`: the project's default actor isolation is
/// `MainActor`, which would otherwise make this struct (and its
/// initialiser) `@MainActor`-isolated — but `NotebookPreferencesStore`'s
/// accessors are `nonisolated` and construct it off the main actor.
nonisolated struct NotebookPreferences: Sendable {
    var autoAddPagesOnScroll: Bool = true
    /// Off by default — discovered through the in-toolbar "try
    /// auto-hide" nudge on the first few notebook opens, then
    /// surfaced as a toggle in the customise panel for ongoing
    /// control. Defaulting on surprised users who weren't expecting
    /// the chrome to disappear mid-stroke.
    var autoHideHeader:       Bool = false
}

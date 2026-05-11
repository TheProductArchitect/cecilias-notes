/// NewNotebookCustomiseTrigger.swift
/// Cecilia's Notes
///
/// Process-local one-shot registry for the "newly-created notebook
/// should auto-open the customise panel" hand-off. The library
/// marks a notebook id when it creates one via "+ new notebook";
/// `EditorView.onAppear` consumes the mark and triggers the panel.
///
/// Why a static registry rather than a `LibraryViewModel` →
/// `EditorViewModel` binding: the editor view-model is created
/// fresh each time the editor mounts, and the create-then-navigate
/// path runs entirely inside the library before the editor's
/// `init` fires. A process-local set is the simplest, decoupled
/// channel between the two — no init-parameter additions, no
/// shared mutable state across runs (the set always starts empty
/// on cold launch). Not persisted: by design, the flag only
/// applies to the immediate transition.

import Foundation

@MainActor
enum NewNotebookCustomiseTrigger {

    /// Notebook ids the library has just created and wants the
    /// editor to auto-customise. Pruned in `consume(_:)`.
    private static var pendingIds: Set<UUID> = []

    /// Mark a freshly-created notebook for auto-customise. Idempotent.
    static func mark(_ id: UUID) {
        pendingIds.insert(id)
    }

    /// Returns `true` iff the id was marked, and removes it from
    /// the set so a subsequent re-entry into the same notebook
    /// doesn't re-open the panel.
    static func consume(_ id: UUID) -> Bool {
        pendingIds.remove(id) != nil
    }
}

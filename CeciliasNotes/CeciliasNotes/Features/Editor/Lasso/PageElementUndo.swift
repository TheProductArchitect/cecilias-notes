import Foundation
import PencilKit
import SwiftData

/// Shared undo plumbing for non-stroke PageElements (shape, sticky
/// note). PKCanvasView owns the page's undoManager because strokes
/// historically registered their own undo via PencilKit; non-stroke
/// element creates/deletes wire into the *same* manager so a single
/// ⌘Z walks back through every page-level edit, regardless of which
/// overlay produced it.
enum PageElementUndo {

    /// Register a create with the canvas undoManager. The first ⌘Z
    /// soft-deletes the new element; the next ⌘⇧Z (redo) brings it
    /// back. Re-registers on each apply so a long undo/redo chain
    /// keeps walking back and forth as long as the user holds the
    /// keys. Notifications fire on each toggle so overlay views
    /// refresh.
    @MainActor
    static func registerCreate(
        elementId: UUID,
        kind: ElementKind,
        canvas: PKCanvasView?,
        actionName: String
    ) {
        guard let manager = canvas?.undoManager else { return }
        registerToggle(
            elementId: elementId,
            kind: kind,
            willDelete: true,                  // first ⌘Z deletes the just-created element
            manager: manager,
            actionName: actionName,
            anchor: canvas!
        )
    }

    /// Register a soft-delete with the canvas undoManager. First ⌘Z
    /// restores `deletedAt` to nil (the element returns); ⌘⇧Z
    /// (redo) re-soft-deletes it. Mirror image of `registerCreate` —
    /// the only difference is the initial `willDelete` polarity,
    /// because the user just performed a delete, so the next
    /// step in the chain (undo) must un-delete.
    ///
    /// Used by the lasso trash badge for shape and sticky-note
    /// elements. Stroke elements aren't covered — PencilKit's
    /// native UndoManager already records stroke edits, and
    /// double-registering would push the user's drawing history
    /// out of sync with what PencilKit thinks it knows.
    @MainActor
    static func registerDelete(
        elementId: UUID,
        kind: ElementKind,
        canvas: PKCanvasView?,
        actionName: String
    ) {
        guard let manager = canvas?.undoManager else { return }
        registerToggle(
            elementId: elementId,
            kind: kind,
            willDelete: false,                 // first ⌘Z restores the just-deleted element
            manager: manager,
            actionName: actionName,
            anchor: canvas!
        )
    }

    /// Recursive toggle registration. `willDelete=true` means
    /// "the next undo/redo step is a soft-delete" — i.e. we're
    /// undoing a creation. After the toggle runs we re-register
    /// with the opposite intent so the next press flips back.
    ///
    /// The whole handler runs SYNCHRONOUSLY inside the undo
    /// invocation. This matters for two reasons:
    ///   • NSUndoManager routes a `registerUndo` call to the REDO
    ///     stack only while `isUndoing` is true. The previous
    ///     implementation deferred the re-registration into a
    ///     `Task { @MainActor }`, which ran after the undo
    ///     invocation ended — the mirror action landed back on the
    ///     UNDO stack, so redo never lit up for element deletes.
    ///   • The model mutation is visible (and the button-state
    ///     poll accurate) the moment undo() returns.
    @MainActor
    private static func registerToggle(
        elementId: UUID,
        kind: ElementKind,
        willDelete: Bool,
        manager: UndoManager,
        actionName: String,
        anchor: AnyObject
    ) {
        manager.registerUndo(withTarget: anchor) { [elementId, kind, willDelete, actionName] anchorRef in
            MainActor.assumeIsolated {
                // Re-register the opposite intent FIRST, while the
                // manager is mid-undo/redo, so it lands on the
                // correct mirror stack.
                registerToggle(
                    elementId: elementId,
                    kind: kind,
                    willDelete: !willDelete,
                    manager: manager,
                    actionName: actionName,
                    anchor: anchorRef
                )
                let context = StorageService.shared.context
                let desc = FetchDescriptor<PageElement>(
                    predicate: #Predicate { $0.id == elementId }
                )
                guard let element = (try? context.fetch(desc))?.first else { return }
                element.deletedAt = willDelete ? Date() : nil
                element.updatedAt = Date()
                do {
                    try context.save()
                } catch {
                    // Undo/redo flips deletedAt on the element row.
                    // A silent save failure here means the user
                    // taps undo, sees nothing happen, and the
                    // chrome state is out of sync with persistence
                    // — exactly the "undo doesn't work for shapes"
                    // class of report.
                    #if DEBUG
                    dlog("[Undo] toggle SAVE FAILED elementId=\(elementId) willDelete=\(willDelete): \(error)")
                    #endif
                }
                postRefreshNotification(for: kind)
            }
        }
        manager.setActionName(actionName)
    }

    /// Fire the per-kind change notification so the right overlay
    /// re-fetches. Stroke elements aren't covered here — PencilKit
    /// owns their undo path natively.
    private static func postRefreshNotification(for kind: ElementKind) {
        switch kind {
        case .shape:
            NotificationCenter.default.post(name: .shapeElementsChanged, object: nil)
        case .stickyNote:
            NotificationCenter.default.post(name: .stickyNotesChanged, object: nil)
        case .text:
            NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        case .image:
            NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil)
        case .audio:
            NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
        case .highlight:
            NotificationCenter.default.post(name: .highlightElementsChanged, object: nil)
        case .stroke, .pdfPage:
            break
        }
    }
}

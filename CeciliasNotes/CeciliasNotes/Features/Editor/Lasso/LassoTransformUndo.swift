import Foundation
import PencilKit
import SwiftData

/// The active page's mounted PKCanvasView — the anchor whose private
/// UndoManager receives page-level undo registrations. Mirrors
/// `EditorViewModel.canvasView` (kept in sync via its `didSet`) so
/// element views that don't hold a viewModel reference (image /
/// sticky / text handle gestures) can still register undo for their
/// direct-manipulation commits.
@MainActor
enum ActivePageCanvas {
    weak static var current: PKCanvasView?
}

/// Stable anchor object for lasso undo registrations. Registrations
/// used to target the PKCanvasView itself — but the warm band
/// RECYCLES canvases while scrolling, and NSUndoManager drops (or
/// dangles) every action whose target is gone, so the lasso undo
/// history silently died after a couple of pages of scrolling
/// ("undo works for a while, then stops"). The canvas is still used
/// to LOCATE the window's UndoManager at registration time; this
/// object only gives the actions an editor-lifetime target.
/// `EditorView` clears anchored actions on dismiss so entries can't
/// outlive their notebook.
final class LassoUndoAnchor {
    @MainActor static let shared = LassoUndoAnchor()
    private init() {}
}

/// Undo plumbing for lasso group transforms (move / resize /
/// rotate). Unlike `PageElementUndo` (a boolean deletedAt toggle),
/// a transform mutates continuous geometry — and the commit path
/// clamps to page bounds, so "apply the inverse transform" would
/// drift at the edges. Snapshots are exact: capture every affected
/// element's geometry (and stroke bytes for stroke elements) before
/// and after the op, undo = write back the before-state, redo = the
/// after-state.
///
/// Registered on the page canvas's private UndoManager (see
/// `CeciliasNotesPKCanvasView.undoManager`) so the toolbar buttons
/// and ⌘Z pick it up like every other page edit.
@MainActor
enum LassoTransformUndo {

    struct ElementSnapshot: Equatable {
        let elementId: UUID
        let kind: ElementKind
        let pageId: UUID
        let normalizedX: Double
        let normalizedY: Double
        let normalizedWidth: Double
        let normalizedHeight: Double
        let rotation: Double
        /// Stroke elements only — full PKDrawing bytes. Geometry
        /// fields above are captured but unused for strokes (their
        /// element rect is the whole-page singleton).
        let strokeData: Data?
    }

    /// Snapshot the current state of the given elements. Call once
    /// BEFORE the transform mutates them and once AFTER.
    static func capture(
        elementIds: [UUID],
        context: ModelContext
    ) -> [ElementSnapshot] {
        var out: [ElementSnapshot] = []
        out.reserveCapacity(elementIds.count)
        for id in elementIds {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == id }
            )
            guard let el = (try? context.fetch(descriptor))?.first else { continue }
            out.append(ElementSnapshot(
                elementId: id,
                kind: el.kind,
                pageId: el.pageId,
                normalizedX: el.normalizedX,
                normalizedY: el.normalizedY,
                normalizedWidth: el.normalizedWidth,
                normalizedHeight: el.normalizedHeight,
                rotation: el.rotation,
                strokeData: el.kind == .stroke ? el.strokeContent?.strokeData : nil
            ))
        }
        return out
    }

    /// Convenience for single-element direct-manipulation commits
    /// (an element's own drag / resize / rotate handles, as opposed
    /// to the lasso chrome): capture the before-state, run the
    /// mutation, capture the after-state, register. Anchors on the
    /// active page's canvas.
    static func withUndo(
        elementId: UUID,
        actionName: String,
        _ mutate: () -> Void
    ) {
        let context = StorageService.shared.context
        let before = capture(elementIds: [elementId], context: context)
        mutate()
        let after = capture(elementIds: [elementId], context: context)
        // Thumbnails key on `page.updatedAt`; element mutations that
        // only stamped `element.updatedAt` left the strip thumbnail
        // stale (visible now that thumbnails composite image
        // elements). One stamp here covers every per-element
        // move/resize/rotate commit.
        if before != after, let pageId = after.first?.pageId {
            StrokeCommit.stampPage(pageId: pageId, context: context)
        }
        register(
            before: before,
            after: after,
            canvas: ActivePageCanvas.current,
            actionName: actionName
        )
    }

    /// Register the undo step for a committed transform. `before`
    /// and `after` must cover the same element set.
    static func register(
        before: [ElementSnapshot],
        after: [ElementSnapshot],
        canvas: PKCanvasView?,
        actionName: String
    ) {
        guard !before.isEmpty, let canvas, let manager = canvas.undoManager else { return }
        // No-op commits (pinch ended at scale 1, drag clamped back to
        // the start) shouldn't burn an undo step.
        guard before != after else { return }
        registerApply(
            state: before, opposite: after,
            manager: manager, anchor: LassoUndoAnchor.shared, actionName: actionName
        )
    }

    /// Recursive register: applying `state` re-registers with the
    /// roles swapped so undo/redo ping-pongs. Runs synchronously
    /// inside the undo invocation — same reasoning as
    /// `PageElementUndo.registerToggle` (a deferred re-register
    /// would land on the undo stack instead of the redo stack).
    private static func registerApply(
        state: [ElementSnapshot],
        opposite: [ElementSnapshot],
        manager: UndoManager,
        anchor: AnyObject,
        actionName: String
    ) {
        manager.registerUndo(withTarget: anchor) { anchorRef in
            MainActor.assumeIsolated {
                registerApply(
                    state: opposite, opposite: state,
                    manager: manager, anchor: anchorRef, actionName: actionName
                )
                apply(state)
            }
        }
        manager.setActionName(actionName)
    }

    /// Write a snapshot set back to the model, refresh caches and
    /// overlays, and drop the (now misplaced) selection chrome.
    private static func apply(_ snapshots: [ElementSnapshot]) {
        let context = StorageService.shared.context
        var strokePageIds: Set<UUID> = []
        var kinds: Set<ElementKind> = []
        for snap in snapshots {
            let id = snap.elementId
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == id }
            )
            guard let el = (try? context.fetch(descriptor))?.first else { continue }
            el.normalizedX      = snap.normalizedX
            el.normalizedY      = snap.normalizedY
            el.normalizedWidth  = snap.normalizedWidth
            el.normalizedHeight = snap.normalizedHeight
            el.rotation         = snap.rotation
            el.updatedAt        = Date()
            if let data = snap.strokeData, let content = el.strokeContent {
                content.strokeData = data
                content.updatedAt  = Date()
                if let drawing = try? PKDrawing(data: data) {
                    StrokeCache.shared.cache(drawing, forPage: snap.pageId)
                }
                StrokeCommit.stampPage(pageId: snap.pageId, context: context)
                strokePageIds.insert(snap.pageId)
            }
            kinds.insert(snap.kind)
        }
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Undo] transform snapshot apply SAVE FAILED: \(error)")
            #endif
        }
        // Overlay + canvas refresh, mirroring LassoGroupOps.
        for kind in kinds {
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
        if !strokePageIds.isEmpty {
            NotificationCenter.default.post(
                name: .strokeContentRewritten,
                object: nil,
                userInfo: ["pageIds": Array(strokePageIds)]
            )
        }
        // The chrome's cached bounds no longer match the restored
        // geometry — clear rather than showing a box around nothing.
        LassoSelectionState.shared.clear()
    }
}

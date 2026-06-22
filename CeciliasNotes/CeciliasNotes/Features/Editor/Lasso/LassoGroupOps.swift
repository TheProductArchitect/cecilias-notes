import CoreGraphics
import Foundation
import PencilKit
import SwiftData
import UIKit

/// Group operations on a `LassoSelectionState` — translate, scale,
/// rotate, delete. Each operation walks the selected elements,
/// dispatches on `ElementKind`, and applies the right primitive:
///
///   • Non-stroke elements: mutate `PageElement.normalizedX/Y/W/H`
///     + `element.rotation` on the SwiftData row directly.
///   • Whole stroke elements: rebuild `StrokeContent.strokeData`
///     from a transformed `PKDrawing`.
///   • Partial stroke selections: split the source PKDrawing's
///     strokes by selected-index, transform the selected ones,
///     stitch back together.
///
/// All coordinates here are **page-pt** (NOT normalised) — the
/// caller translates from gesture deltas before dispatching here.
/// The group helpers normalise on commit when writing
/// `PageElement.normalizedX/Y`.
@MainActor
enum LassoGroupOps {

    // MARK: - Translate

    /// Translate every member of the selection by `delta` (in
    /// page-pt). Updates the model + the cached
    /// `selectionBounds` so the chrome stays aligned. Posts no
    /// notification; consumers (overlay views) read SwiftData
    /// directly through `@Bindable`.
    static func translate(
        selection: LassoSelectionState,
        delta: CGSize,
        pageSize: CGSize,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        guard delta != .zero, pageSize.width > 0, pageSize.height > 0 else { return }

        let dxNorm = delta.width  / pageSize.width
        let dyNorm = delta.height / pageSize.height

        // Cross-page handoff fast-path: a single non-stroke element
        // being dragged past the top or bottom of the page hands off
        // to the canvas coordinator (same path the per-image drag
        // takes). Without this, the lasso translate clamps every
        // element into the current page — the user could move an
        // image freely between pages by dragging directly on it but
        // not via the lasso chrome.
        //
        // Partial stroke selections do NOT block this path. The
        // common case is the user lassoes around a shape that also
        // happens to overlap a stroke fragment — Wave 1 of this
        // fix required partialStrokeSelections.isEmpty, which
        // device logs showed as the most frequent block on the
        // hand-off. When the hand-off does fire we drop the
        // partial-stroke set on the floor: the strokes were never
        // meant to travel with the element across pages, and
        // selection.clear() at the end discards them either way.
        if selection.selectedElementIds.count == 1,
           let onlyId = selection.selectedElementIds.first,
           let element = fetch(onlyId, context: context),
           element.kind != .stroke,
           element.kind != .pdfPage {
            let proposedY = element.normalizedY + dyNorm
            if proposedY < 0 || proposedY > 1 - element.normalizedHeight {
                let proposedX = element.normalizedX + dxNorm
                NotificationCenter.default.post(
                    name: .imageElementCrossPageHandoffRequested,
                    object: nil,
                    userInfo: [
                        "elementId": element.id,
                        "currentPageId": element.pageId,
                        "proposedNormX": proposedX,
                        "proposedNormY": proposedY
                    ]
                )
                selection.clear()
                return
            }
        }

        // Whole-element members (includes whole stroke elements).
        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
            switch element.kind {
            case .stroke:
                applyTransformToStroke(
                    element: element,
                    indices: nil,                 // nil = transform every PKStroke
                    transform: LassoMath.translation(dx: delta.width, dy: delta.height),
                    context: context
                )
            default:
                // Clamp so the element stays fully within the page.
                element.normalizedX = max(0, min(1 - element.normalizedWidth,  element.normalizedX + dxNorm))
                element.normalizedY = max(0, min(1 - element.normalizedHeight, element.normalizedY + dyNorm))
                element.updatedAt   = Date()
            }
        }
        // Partial-stroke members.
        for (elementId, indices) in selection.partialStrokeSelections {
            guard let element = fetch(elementId, context: context) else { continue }
            applyTransformToStroke(
                element: element,
                indices: indices,
                transform: LassoMath.translation(dx: delta.width, dy: delta.height),
                context: context
            )
        }
        try? context.save()

        // Shift the cached bounding box too — caller already
        // composed the gesture delta; no need to re-run intersection.
        let newBounds = selection.selectionBounds.offsetBy(dx: delta.width, dy: delta.height)
        selection.updateBounds(newBounds)
    }

    // MARK: - Scale

    /// Aspect-locked scale around the selection bounding box's
    /// centre. `scale` < 1 shrinks, `scale` > 1 grows. Anchor
    /// derived from the cached `selectionBounds` so the visible
    /// bbox stays put while corners move.
    static func scale(
        selection: LassoSelectionState,
        scale s: CGFloat,
        pageSize: CGSize,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        guard s > 0, s != 1, pageSize.width > 0, pageSize.height > 0 else { return }
        let anchor = CGPoint(x: selection.selectionBounds.midX,
                             y: selection.selectionBounds.midY)
        let strokeTransform = LassoMath.scale(sx: s, sy: s, around: anchor)

        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
            switch element.kind {
            case .stroke:
                applyTransformToStroke(
                    element: element, indices: nil,
                    transform: strokeTransform, context: context
                )
            default:
                scaleNonStrokeElement(element, anchor: anchor,
                                      scale: s, pageSize: pageSize)
            }
        }
        for (elementId, indices) in selection.partialStrokeSelections {
            guard let element = fetch(elementId, context: context) else { continue }
            applyTransformToStroke(
                element: element, indices: indices,
                transform: strokeTransform, context: context
            )
        }
        try? context.save()

        // Recompute selection bounds around the same anchor.
        let oldBounds = selection.selectionBounds
        let newW = oldBounds.width  * s
        let newH = oldBounds.height * s
        let newBounds = CGRect(
            x: anchor.x - newW / 2,
            y: anchor.y - newH / 2,
            width: newW, height: newH
        )
        selection.updateBounds(newBounds)
    }

    /// Free-axis scale: width scales by `scaleX`, height by `scaleY`,
    /// each around the selection bounding box's centre. Called when
    /// Shift is held during a corner-resize drag.
    static func scaleXY(
        selection: LassoSelectionState,
        scaleX sx: CGFloat,
        scaleY sy: CGFloat,
        pageSize: CGSize,
        anchor: CGPoint? = nil,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        guard sx > 0, sy > 0, !(sx == 1 && sy == 1) else { return }
        // Default anchor (nil) keeps the legacy bbox-centre
        // behaviour so existing callers don't change semantics;
        // the lasso resize gesture now passes the OPPOSITE-corner
        // point so the edge the user nailed stays nailed.
        let anchor = anchor ?? CGPoint(
            x: selection.selectionBounds.midX,
            y: selection.selectionBounds.midY
        )
        let strokeTransform = LassoMath.scale(sx: sx, sy: sy, around: anchor)

        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
            switch element.kind {
            case .stroke:
                applyTransformToStroke(
                    element: element, indices: nil,
                    transform: strokeTransform, context: context
                )
            default:
                scaleXYNonStrokeElement(element, anchor: anchor,
                                        scaleX: sx, scaleY: sy, pageSize: pageSize)
            }
        }
        for (elementId, indices) in selection.partialStrokeSelections {
            guard let element = fetch(elementId, context: context) else { continue }
            applyTransformToStroke(
                element: element, indices: indices,
                transform: strokeTransform, context: context
            )
        }
        try? context.save()

        // Recompute bbox by pivoting every corner around `anchor`.
        // This generalises both the legacy bbox-centre anchor
        // (dxFromAnchor / dyFromAnchor are 0, so the centre
        // stays put) AND the new opposite-corner anchor (the
        // centre shifts as the corners scale around the fixed
        // anchor point).
        let oldBounds = selection.selectionBounds
        let dxFromAnchor = oldBounds.midX - anchor.x
        let dyFromAnchor = oldBounds.midY - anchor.y
        let newMidX = anchor.x + dxFromAnchor * sx
        let newMidY = anchor.y + dyFromAnchor * sy
        let newWidth  = oldBounds.width  * sx
        let newHeight = oldBounds.height * sy
        let newBounds = CGRect(
            x: newMidX - newWidth  / 2,
            y: newMidY - newHeight / 2,
            width:  newWidth,
            height: newHeight
        )
        selection.updateBounds(newBounds)
    }

    // MARK: - Rotate

    /// Rotate every selected element by `angle` (radians) around
    /// the selection bounding box's centre. Non-stroke elements
    /// pick up the rotation in two pieces: their own `rotation`
    /// field rotates by `angle`, and their CENTRE point rotates
    /// around the anchor by the same angle (so their position
    /// follows the group rotation rather than spinning in place).
    static func rotate(
        selection: LassoSelectionState,
        angle: CGFloat,
        pageSize: CGSize,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        guard angle != 0, pageSize.width > 0, pageSize.height > 0 else { return }
        let anchor = CGPoint(x: selection.selectionBounds.midX,
                             y: selection.selectionBounds.midY)
        let strokeTransform = LassoMath.rotation(angle: angle, around: anchor)

        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
            switch element.kind {
            case .stroke:
                applyTransformToStroke(
                    element: element, indices: nil,
                    transform: strokeTransform, context: context
                )
            default:
                rotateNonStrokeElement(element, anchor: anchor,
                                       angle: angle, pageSize: pageSize)
            }
        }
        for (elementId, indices) in selection.partialStrokeSelections {
            guard let element = fetch(elementId, context: context) else { continue }
            applyTransformToStroke(
                element: element, indices: indices,
                transform: strokeTransform, context: context
            )
        }
        try? context.save()
        // Rotation doesn't change the bbox of a rotated set in a
        // simple way; recompute from the elements' new bounds.
        // For v1 we leave the bbox as-is — the next intersection
        // run will refresh it. The user typically completes
        // rotate → drag/delete, not rotate → resize.
    }

    // MARK: - Delete

    /// Soft-delete every selected whole element + strip the
    /// selected indices from every partially-selected stroke
    /// element's PKDrawing. Clears the selection on success.
    ///
    /// `canvas` is the PKCanvasView whose `undoManager` records the
    /// per-element undo entries. Without it, deletes succeed but
    /// ⌘Z (or the toolbar undo button) can't bring shapes /
    /// sticky-notes back — which is the "undo doesn't work for
    /// shapes" bug. Strokes deleted by lasso are NOT registered
    /// here; PencilKit owns their undo via `applyTransformToStroke`'s
    /// drawing rewrite, and double-registering would diverge from
    /// what PencilKit thinks it knows.
    static func delete(
        selection: LassoSelectionState,
        canvas: PKCanvasView? = nil,
        context: ModelContext? = nil
    ) {
        let context = context ?? StorageService.shared.context
        var deletedAnyShape = false
        var deletedAnySticky = false
        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
            if element.kind == .shape { deletedAnyShape = true }
            if element.kind == .stickyNote { deletedAnySticky = true }
            // Register undo BEFORE the delete so the undo manager's
            // anchor (the canvas view) is still alive and the
            // element is still findable on the next ⌘Z.
            switch element.kind {
            case .shape:
                PageElementUndo.registerDelete(
                    elementId: element.id,
                    kind: .shape,
                    canvas: canvas,
                    actionName: "Delete Shape"
                )
            case .stickyNote:
                PageElementUndo.registerDelete(
                    elementId: element.id,
                    kind: .stickyNote,
                    canvas: canvas,
                    actionName: "Delete Sticky Note"
                )
            default:
                break
            }
            element.deletedAt = Date()
            element.updatedAt = Date()
        }
        for (elementId, indices) in selection.partialStrokeSelections {
            guard let element = fetch(elementId, context: context),
                  let content = element.strokeContent,
                  let drawing = try? PKDrawing(data: content.strokeData)
            else { continue }
            let kept = drawing.strokes.enumerated()
                .filter { !indices.contains($0.offset) }
                .map(\.element)
            let newDrawing = PKDrawing(strokes: kept)
            content.strokeData = newDrawing.dataRepresentation()
            content.updatedAt  = Date()
            element.updatedAt  = Date()
            // Cache write-through so the next canvas mount sees the
            // truncated drawing instead of re-decoding stale bytes.
            StrokeCache.shared.cache(newDrawing, forPage: element.pageId)
        }
        try? context.save()
        // Shape overlay listens on this notification to re-fetch its
        // page-element list. Without it the shape stays painted on
        // screen even though it's soft-deleted, and the lasso can't
        // re-select what it visually still sees because the underlying
        // record is filtered out by `deletedAt == nil`.
        if deletedAnyShape {
            NotificationCenter.default.post(name: .shapeElementsChanged, object: nil)
        }
        if deletedAnySticky {
            NotificationCenter.default.post(name: .stickyNotesChanged, object: nil)
        }
        selection.clear()
    }

    // MARK: - Stroke transform plumbing

    /// Apply `transform` to a stroke element's PKDrawing. `indices
    /// == nil` means "every stroke"; otherwise transform only the
    /// strokes at those indices, leaving the others untouched.
    private static func applyTransformToStroke(
        element: PageElement,
        indices: Set<Int>?,
        transform: CGAffineTransform,
        context: ModelContext
    ) {
        guard let content = element.strokeContent,
              let drawing = try? PKDrawing(data: content.strokeData)
        else { return }
        let strokes = drawing.strokes
        guard !strokes.isEmpty else { return }

        var newStrokes: [PKStroke] = []
        newStrokes.reserveCapacity(strokes.count)
        for (i, stroke) in strokes.enumerated() {
            if let indices, !indices.contains(i) {
                newStrokes.append(stroke)
            } else {
                var s = stroke
                s.transform = s.transform.concatenating(transform)
                newStrokes.append(s)
            }
        }
        let newDrawing = PKDrawing(strokes: newStrokes)
        content.strokeData = newDrawing.dataRepresentation()
        content.updatedAt  = Date()
        element.updatedAt  = Date()
        StrokeCache.shared.cache(newDrawing, forPage: element.pageId)
    }

    /// Scale a non-stroke element's centre + dimensions around
    /// `anchor`. Anchor is in page-pt; pageSize is the page's
    /// dimensions in pt so we can round-trip through normalised
    /// coords without losing precision.
    private static func scaleNonStrokeElement(
        _ element: PageElement,
        anchor: CGPoint,
        scale s: CGFloat,
        pageSize: CGSize
    ) {
        let currentCentreX = (element.normalizedX + element.normalizedWidth  / 2) * pageSize.width
        let currentCentreY = (element.normalizedY + element.normalizedHeight / 2) * pageSize.height
        let newCentreX = anchor.x + (currentCentreX - anchor.x) * s
        let newCentreY = anchor.y + (currentCentreY - anchor.y) * s
        let newWidth   = element.normalizedWidth  * Double(s)
        let newHeight  = element.normalizedHeight * Double(s)
        let newCentreXNorm = Double(newCentreX) / Double(pageSize.width)
        let newCentreYNorm = Double(newCentreY) / Double(pageSize.height)
        // Clamp so the element stays inside the page bounds even
        // when the group scale would push a corner outside.
        let clampedX = max(0, min(1 - newWidth,  newCentreXNorm - newWidth  / 2))
        let clampedY = max(0, min(1 - newHeight, newCentreYNorm - newHeight / 2))
        element.normalizedX      = clampedX
        element.normalizedY      = clampedY
        element.normalizedWidth  = max(0.01, min(1, newWidth))
        element.normalizedHeight = max(0.01, min(1, newHeight))
        element.updatedAt        = Date()
    }

    private static func scaleXYNonStrokeElement(
        _ element: PageElement,
        anchor: CGPoint,
        scaleX sx: CGFloat,
        scaleY sy: CGFloat,
        pageSize: CGSize
    ) {
        let currentCX = (element.normalizedX + element.normalizedWidth  / 2) * pageSize.width
        let currentCY = (element.normalizedY + element.normalizedHeight / 2) * pageSize.height
        let newCX = anchor.x + (currentCX - anchor.x) * sx
        let newCY = anchor.y + (currentCY - anchor.y) * sy
        let newWidth  = element.normalizedWidth  * Double(sx)
        let newHeight = element.normalizedHeight * Double(sy)
        let newCXNorm = Double(newCX) / Double(pageSize.width)
        let newCYNorm = Double(newCY) / Double(pageSize.height)
        let clampedX = max(0, min(1 - newWidth,  newCXNorm - newWidth  / 2))
        let clampedY = max(0, min(1 - newHeight, newCYNorm - newHeight / 2))
        element.normalizedX      = clampedX
        element.normalizedY      = clampedY
        element.normalizedWidth  = max(0.01, min(1, newWidth))
        element.normalizedHeight = max(0.01, min(1, newHeight))
        element.updatedAt        = Date()
    }

    /// Rotate a non-stroke element's centre around `anchor` and
    /// bump its own `rotation` by `angle`. Position math runs in
    /// page-pt; the element ends up back in normalised coords.
    private static func rotateNonStrokeElement(
        _ element: PageElement,
        anchor: CGPoint,
        angle: CGFloat,
        pageSize: CGSize
    ) {
        let currentCentreX = (element.normalizedX + element.normalizedWidth  / 2) * pageSize.width
        let currentCentreY = (element.normalizedY + element.normalizedHeight / 2) * pageSize.height
        let centre = CGPoint(x: currentCentreX, y: currentCentreY)
        let rotated = centre.applying(
            LassoMath.rotation(angle: angle, around: anchor)
        )
        let newXNorm = Double(rotated.x) / Double(pageSize.width)  - element.normalizedWidth  / 2
        let newYNorm = Double(rotated.y) / Double(pageSize.height) - element.normalizedHeight / 2
        element.normalizedX = max(0, min(1 - element.normalizedWidth,  newXNorm))
        element.normalizedY = max(0, min(1 - element.normalizedHeight, newYNorm))
        element.rotation   += Double(angle)
        element.updatedAt   = Date()
    }

    // MARK: - Fetch helper

    private static func fetch(_ id: UUID, context: ModelContext) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil }
        )
        return (try? context.fetch(descriptor))?.first
    }
}

import CoreGraphics
import Foundation
import PencilKit
import SwiftData

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
        context: ModelContext = StorageService.shared.context
    ) {
        guard delta != .zero, pageSize.width > 0, pageSize.height > 0 else { return }

        let dxNorm = delta.width  / pageSize.width
        let dyNorm = delta.height / pageSize.height

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
                element.normalizedX += dxNorm
                element.normalizedY += dyNorm
                element.updatedAt    = Date()
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
        context: ModelContext = StorageService.shared.context
    ) {
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
        context: ModelContext = StorageService.shared.context
    ) {
        guard pageSize.width > 0, pageSize.height > 0 else { return }
        guard sx > 0, sy > 0, !(sx == 1 && sy == 1) else { return }
        let anchor = CGPoint(x: selection.selectionBounds.midX,
                             y: selection.selectionBounds.midY)
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

        let oldBounds = selection.selectionBounds
        let newBounds = CGRect(
            x: anchor.x - oldBounds.width  * sx / 2,
            y: anchor.y - oldBounds.height * sy / 2,
            width:  oldBounds.width  * sx,
            height: oldBounds.height * sy
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
        context: ModelContext = StorageService.shared.context
    ) {
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
    static func delete(
        selection: LassoSelectionState,
        context: ModelContext = StorageService.shared.context
    ) {
        for elementId in selection.selectedElementIds {
            guard let element = fetch(elementId, context: context) else { continue }
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

import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Page-scoped, app-wide singleton observable that tracks the
/// current lasso selection — which `PageElement`s are selected,
/// plus the per-PKDrawing partial-stroke indices for any stroke
/// element only partially captured by the lasso.
///
/// Step 9 — the selection model behind freeform / marquee lasso.
/// The selection persists across tool changes (the user can
/// switch from lasso to a drawing tool and the selection chrome
/// stays visible) but clears when the active page changes
/// (page-scoped per the architecture spec).
@MainActor
final class LassoSelectionState: ObservableObject {

    static let shared = LassoSelectionState()
    private init() {
        // Restore last-used mode from UserDefaults so the user's
        // preferred lasso gesture survives app restarts.
        if let raw = UserDefaults.standard.string(forKey: Self.modeKey),
           let saved = LassoMath.Mode(rawValue: raw) {
            self.mode = saved
        } else {
            self.mode = .freeform
        }
    }

    private static let modeKey = "lasso.mode"

    // MARK: - Selection identity

    /// PageElement IDs currently in the lasso selection.
    /// Includes whole-stroke elements (those whose every PKStroke
    /// landed in the lasso) AND whichever non-stroke elements'
    /// centres landed in the lasso. Excludes stroke elements that
    /// are *only* partially selected — those live in
    /// `partialStrokeSelections` and don't get a whole-element
    /// chrome treatment.
    @Published private(set) var selectedElementIds: Set<UUID> = []

    /// Per-element partial PKStroke index sets — for stroke
    /// elements where the lasso captured only some of the strokes.
    /// Keyed by `PageElement.id`; value is the set of indices into
    /// the element's `StrokeContent.strokeData` PKDrawing.strokes.
    @Published private(set) var partialStrokeSelections: [UUID: Set<Int>] = [:]

    /// The page whose elements the current selection refers to.
    /// `nil` when nothing is selected. Drives the page-scope rule
    /// — navigating to a different page calls `clear()` (the per-
    /// page lasso overlay observes this and emits the call).
    @Published private(set) var pageId: UUID?

    /// Axis-aligned bounding box of the selection in page-pt
    /// coordinates (NOT normalised). Used by the selection chrome
    /// to draw the bbox + handles. Empty when nothing is selected.
    @Published private(set) var selectionBounds: CGRect = .zero

    /// Convex hull of the selected content in page-pt coordinates —
    /// set only for freeform lassos, empty otherwise. When present,
    /// the chrome draws this hugging outline instead of the
    /// rectangular bounding box (the rect still drives handles,
    /// badge placement, and gesture hit areas). Remapped alongside
    /// `selectionBounds` on every committed transform.
    @Published private(set) var hullPoints: [CGPoint] = []

    /// Monotonic mutation counter. Bumped by every `setSelection` /
    /// `clear`. The editor-level "tap anywhere clears the selection"
    /// gesture snapshots this when the tap ends and only clears if
    /// it is unchanged one runloop tick later — i.e. the tap itself
    /// didn't select something (cursor-tap on a shape) or already
    /// clear (the chrome's delete badge). Without this, the global
    /// clear races whatever the tap actually hit.
    private(set) var selectionVersion: Int = 0

    // MARK: - Mode

    /// Active lasso gesture mode (freeform vs marquee). Persisted
    /// to UserDefaults on every change so the user's last pick
    /// survives a fresh launch.
    @Published var mode: LassoMath.Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    // MARK: - Transient drag state
    //
    // Lives on `LassoLiveDrag.shared` — split off this object so
    // 60 Hz gesture updates don't re-publish the selection state
    // and force the overlay to re-render every tick. See the
    // header on that file for the flicker-fix rationale.

    // MARK: - Mutators

    /// Replace the selection wholesale. Called by the lasso
    /// overlay on `.onEnded` after intersection testing completes.
    /// Empty inputs collapse to `clear()` so the chrome disappears
    /// when the user lassoes empty space.
    func setSelection(
        elementIds: Set<UUID>,
        partialStrokes: [UUID: Set<Int>],
        pageId: UUID,
        bounds: CGRect,
        hull: [CGPoint] = []
    ) {
        guard !elementIds.isEmpty || !partialStrokes.isEmpty else {
            clear()
            return
        }
        self.selectedElementIds      = elementIds
        self.partialStrokeSelections = partialStrokes
        self.pageId                  = pageId
        self.selectionBounds         = bounds
        self.hullPoints              = hull
        selectionVersion &+= 1
        LassoLiveDrag.shared.reset()
    }

    /// Update the cached bounding box after a committed move /
    /// resize / rotate so the chrome stays aligned with the new
    /// element positions without re-running intersection.
    ///
    /// The hull outline follows: with `hullTransform` (rotation —
    /// where a rect-to-rect map would leave the hull unrotated)
    /// the points are mapped through it directly; otherwise
    /// they're remapped rect-to-rect from the old bounds to
    /// `newBounds`, which is exact for translate and anchored
    /// scale (both are affine maps that send the old bbox onto
    /// the new one).
    func updateBounds(_ newBounds: CGRect, hullTransform: CGAffineTransform? = nil) {
        guard pageId != nil else { return }
        if !hullPoints.isEmpty {
            if let t = hullTransform {
                hullPoints = hullPoints.map { $0.applying(t) }
            } else {
                let old = selectionBounds
                if old.width > 0.5, old.height > 0.5,
                   newBounds.width > 0.5, newBounds.height > 0.5 {
                    let sx = newBounds.width  / old.width
                    let sy = newBounds.height / old.height
                    hullPoints = hullPoints.map {
                        CGPoint(x: newBounds.minX + ($0.x - old.minX) * sx,
                                y: newBounds.minY + ($0.y - old.minY) * sy)
                    }
                } else {
                    hullPoints = []
                }
            }
        }
        selectionBounds = newBounds
    }

    /// Clear everything — selection ids, partials, bounds, page,
    /// transient state. The chrome disappears on the next render.
    func clear() {
        selectedElementIds      = []
        partialStrokeSelections = [:]
        pageId                  = nil
        selectionBounds         = .zero
        hullPoints              = []
        selectionVersion &+= 1
        LassoLiveDrag.shared.reset()
    }

    /// `true` when the lasso has anything to show chrome for —
    /// either at least one whole element selected, or at least one
    /// partially-selected stroke element.
    var hasSelection: Bool {
        !selectedElementIds.isEmpty || !partialStrokeSelections.isEmpty
    }
}

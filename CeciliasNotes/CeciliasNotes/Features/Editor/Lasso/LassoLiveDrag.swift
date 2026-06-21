import Combine
import CoreGraphics
import Foundation
import SwiftUI

/// Tiny sibling of `LassoSelectionState` carrying only the live
/// in-flight drag state (`transientOffset` + `isManipulating`).
///
/// Why a separate object: `LassoSelectionState` is observed by
/// `LassoOverlayView`, which means every `@Published` mutation on
/// that state — including the 60 Hz `transientOffset` updates a
/// drag gesture produces — re-evaluates the overlay's body.
/// The body work was heavy enough that at normal drag speeds
/// SwiftUI couldn't keep up and the chrome flickered between
/// the local `@State` `dragOffset` (synchronous) and the
/// `@Published` value (next-runloop).
///
/// Splitting the transient publishers off lets the overlay write
/// to this object without re-rendering itself. The only readers
/// are element views (text blocks today; potential image / shape
/// preview consumers in future) — they observe this object
/// directly and ignore the larger selection state for live-drag
/// purposes.
@MainActor
final class LassoLiveDrag: ObservableObject {

    static let shared = LassoLiveDrag()
    private init() {}

    /// Live in-flight translation applied to selected elements
    /// while the user is dragging the chrome. Reset to `.zero` on
    /// `.onEnded`; the commit then writes the model.
    @Published var transientOffset: CGSize = .zero

    /// `true` while the user is mid-gesture inside the selection
    /// chrome — drives "follow the drag" behaviour on element
    /// views so they preview the move/resize/rotate before commit.
    @Published var isManipulating: Bool = false

    /// Live in-flight rotation in radians, around `rotationCenter`,
    /// applied to every selected element while the user is
    /// dragging the rotation knob. `0` outside the rotate gesture.
    /// Element views that mount a `.transformEffect` over this
    /// preview-rotate together so the bbox and the actual content
    /// stay aligned — instead of the bbox spinning while the
    /// elements stay still and then snap to position on release.
    @Published var rotationAngle: CGFloat = 0

    /// The page-coord pivot for `rotationAngle`. Set by the
    /// rotation gesture to the selection's bbox centre.
    @Published var rotationCenter: CGPoint = .zero

    /// Convenience: the CGAffineTransform that rotates around
    /// `rotationCenter` by `rotationAngle`. Elements apply this
    /// via `.transformEffect` to render the live preview.
    var rotationTransform: CGAffineTransform {
        guard rotationAngle != 0 else { return .identity }
        return CGAffineTransform.identity
            .translatedBy(x: rotationCenter.x, y: rotationCenter.y)
            .rotated(by: rotationAngle)
            .translatedBy(x: -rotationCenter.x, y: -rotationCenter.y)
    }

    func reset() {
        transientOffset = .zero
        isManipulating = false
        rotationAngle = 0
        rotationCenter = .zero
    }
}

// MARK: - Live rotation preview modifier

/// Attaches a live `.transformEffect` to any element view whose
/// underlying `PageElement.id` is in the lasso selection while a
/// rotation gesture is in flight. The transform pivots the
/// element around the bbox centre, so during the drag the visible
/// content rotates with the dashed bounding rectangle instead of
/// standing still and snapping into place on release.
///
/// Non-selected element views read `isManipulating == false` /
/// `rotationAngle == 0` and skip the transform entirely.
struct LassoRotationPreviewModifier: ViewModifier {

    let elementId: UUID

    @ObservedObject private var selection = LassoSelectionState.shared
    @ObservedObject private var liveDrag  = LassoLiveDrag.shared

    private var isPreviewing: Bool {
        liveDrag.isManipulating
            && liveDrag.rotationAngle != 0
            && selection.selectedElementIds.contains(elementId)
    }

    func body(content: Content) -> some View {
        if isPreviewing {
            content.transformEffect(liveDrag.rotationTransform)
        } else {
            content
        }
    }
}

extension View {
    /// Apply the rotation preview to an element view. Call after
    /// the view's own `.position(...)` so the transform composes
    /// with the element's resting placement.
    func lassoRotationPreview(elementId: UUID) -> some View {
        modifier(LassoRotationPreviewModifier(elementId: elementId))
    }
}

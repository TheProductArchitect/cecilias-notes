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

    func reset() {
        transientOffset = .zero
        isManipulating = false
        rotationAngle = 0
        rotationCenter = .zero
    }
}

// MARK: - Live rotation preview modifier

/// Rotates an element around its OWN centre: the committed
/// `element.rotation` plus any in-flight lasso-rotation delta for
/// this element. Both apply via `.rotationEffect(anchor: .center)`,
/// which anchors on the CENTRE OF THE VIEW IT MODIFIES.
///
/// This MUST be applied to the framed element BEFORE `.position(...)`.
/// `.position` expands the view to fill the page, so a rotation
/// applied after it anchors on the PAGE centre — making every
/// off-centre element revolve around a point on the page instead of
/// spinning in place. Applied before `.position`, the modified view
/// IS the element frame, so the anchor is the element's own centre.
struct LassoRotationPreviewModifier: ViewModifier {

    let elementId: UUID
    /// The committed rotation for this element (radians).
    let committed: Double

    @ObservedObject private var selection = LassoSelectionState.shared
    @ObservedObject private var liveDrag  = LassoLiveDrag.shared

    private var liveDelta: Double {
        guard liveDrag.isManipulating,
              liveDrag.rotationAngle != 0,
              selection.selectedElementIds.contains(elementId)
        else { return 0 }
        return liveDrag.rotationAngle
    }

    func body(content: Content) -> some View {
        content.rotationEffect(.radians(committed + liveDelta), anchor: .center)
    }
}

extension View {
    /// Rotate an element around its OWN centre — committed angle plus
    /// the live lasso-rotation preview. Apply to the FRAMED element
    /// BEFORE `.position(...)` (see the modifier's note).
    func elementRotation(elementId: UUID, radians: Double) -> some View {
        modifier(LassoRotationPreviewModifier(elementId: elementId, committed: radians))
    }
}

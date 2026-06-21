import Combine
import CoreGraphics
import Foundation

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

    func reset() {
        transientOffset = .zero
        isManipulating = false
    }
}

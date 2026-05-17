import CoreGraphics
import Foundation

/// Single placement primitive for every per-page editor overlay
/// (images, audio pins, lecture cards, sticky notes, text blocks).
///
/// **The contract**: every overlay receives a `PageCoordinateSpace` from
/// its parent and uses it for *all* position math. No overlay computes
/// page dimensions itself, and no overlay reads the renderer's effective
/// height (base + auto-extension) for placement — effective height is
/// reserved for the renderer's own frame and the scroll content size.
///
/// Why this exists: prior to its introduction, four overlay layers each
/// derived their own page size from a different ancestor (one used base
/// size correctly, two read the renderer's effective height via
/// `GeometryReader.proxy.size`, one reached into the view-model's
/// current page directly). When the last page auto-extended after a
/// stroke, the layers using effective height drifted downward
/// proportionally — visible as audio pins jumping down after a scroll
/// near the bottom, lecture cards rendering above the page bounds,
/// etc. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §2.
///
/// `PageCoordinateSpace` is intentionally a value type with no
/// reference semantics — passing it down through SwiftUI overlay views
/// is cheap, and there's no shared state to mutate or observe.
struct PageCoordinateSpace: Equatable, Sendable, Hashable {

    /// The page's stable base size, derived from `Page.pageSize.pointSize`.
    /// Never includes auto-extension. Two pages of the same `PageSize`
    /// enum case produce identical coordinate spaces; the auto-extended
    /// region of the last page belongs to the renderer's frame, not to
    /// the placement coordinate space.
    let baseSize: CGSize

    init(baseSize: CGSize) {
        self.baseSize = baseSize
    }

    /// Convenience: build directly from a `PageSize`.
    init(pageSize: PageSize) {
        self.init(baseSize: pageSize.pointSize)
    }

    // MARK: - Conversions

    /// Convert a normalised (0–1) coordinate to a point coordinate within
    /// the page's base rect.
    func point(fromNormalized n: CGPoint) -> CGPoint {
        CGPoint(x: n.x * baseSize.width, y: n.y * baseSize.height)
    }

    /// Convert a normalised (0–1) size to a point size.
    func size(fromNormalized n: CGSize) -> CGSize {
        CGSize(width: n.width * baseSize.width, height: n.height * baseSize.height)
    }

    /// Convert a normalised rect to a point rect.
    func rect(fromNormalized n: CGRect) -> CGRect {
        CGRect(
            origin: point(fromNormalized: n.origin),
            size:   size(fromNormalized: n.size)
        )
    }

    /// Convert a point coordinate within the page to a normalised (0–1)
    /// value. Caller is responsible for clamping if a strict bounds
    /// guarantee is required.
    func normalized(fromPoint p: CGPoint) -> CGPoint {
        guard baseSize.width > 0, baseSize.height > 0 else { return .zero }
        return CGPoint(x: p.x / baseSize.width, y: p.y / baseSize.height)
    }

    /// Convert a point size to a normalised size.
    func normalized(fromSize s: CGSize) -> CGSize {
        guard baseSize.width > 0, baseSize.height > 0 else { return .zero }
        return CGSize(width: s.width / baseSize.width, height: s.height / baseSize.height)
    }
}

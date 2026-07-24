import CoreGraphics

/// Pure, view-independent geometry for the editor's "magnetic"
/// behaviours — cross-page element hand-off snapping and the
/// zoom / centre content-inset math.
///
/// Extracted from `ContinuousCanvasView` so the decisions can be
/// unit-tested without a live `UIScrollView` or mounted page hosts.
/// The coordinator is a thin adapter: it turns its page hosts into
/// `PageBand`s and its scroll geometry into scalars, calls in here,
/// and applies the result.
///
/// `nonisolated` so the pure math is callable from any context
/// (including the non-`@MainActor` unit-test target) under the
/// project's default main-actor isolation.
nonisolated enum MagneticSnapMath {

    // MARK: - Horizontal centring

    struct HorizontalCentering: Equatable {
        /// Symmetric left/right content inset that centres the page.
        let inset: CGFloat
        /// The single valid resting `contentOffset.x` when the page fits
        /// horizontally — `nil` when the page overflows the viewport
        /// (zoomed in) and is free to pan.
        let centeredOffsetX: CGFloat?
    }

    /// Everything needed to centre the document horizontally at a given
    /// zoom, for ANY screen size.
    ///
    /// The subtlety this encodes: setting a symmetric `contentInset` is
    /// necessary but NOT sufficient. UIScrollView does not reliably move
    /// `contentOffset.x` to the one valid resting position when the
    /// content fits, so a page can sit pinned at `offset.x == 0` — glued
    /// to the left edge with all the slack piled on the right ("the
    /// notebook isn't centred / leans left"). When the page fits there
    /// is exactly one centred offset, `-inset`; the caller must pin it
    /// explicitly. When the page overflows (`displayed > bounds`) there
    /// is no single resting offset — it pans freely — so `inset == 0`
    /// and `centeredOffsetX == nil`.
    static func horizontalCentering(
        boundsWidth: CGFloat,
        contentWidth: CGFloat,
        zoomScale: CGFloat
    ) -> HorizontalCentering {
        let displayed = contentWidth * zoomScale
        let inset = max(0, (boundsWidth - displayed) / 2)
        let fits = displayed <= boundsWidth
        return HorizontalCentering(inset: inset, centeredOffsetX: fits ? -inset : nil)
    }

    // MARK: - Cross-page hand-off

    nonisolated enum PageEdge: Equatable { case top, bottom }

    /// One mounted page's vertical extent in content-view coordinates.
    nonisolated struct PageBand: Equatable {
        let index: Int
        let minY: CGFloat
        let maxY: CGFloat
    }

    /// Resolve the destination page (and, when magnetised, which edge
    /// to pin to) for a cross-page element hand-off.
    ///
    /// 1. Strict containment: the projected Y lands inside a page →
    ///    that page hosts the element at the free (in-page) fraction,
    ///    `edge == nil`.
    /// 2. Magnetic fallback: the drop landed in the inter-page gutter,
    ///    or past the first/last page, so no band contains it. Rather
    ///    than giving up — which reverted the element all the way to
    ///    its origin — snap to the nearest page edge: the END
    ///    (`.bottom`) of the page above the gap, or the BEGINNING
    ///    (`.top`) of the page below it, whichever edge is closer to
    ///    where the finger let go.
    ///
    /// Returns `nil` only when there are no bands at all.
    static func resolveCrossPage(pointY: CGFloat, bands: [PageBand]) -> (band: PageBand, edge: PageEdge?)? {
        if let contained = bands.first(where: { pointY >= $0.minY && pointY < $0.maxY }) {
            return (contained, nil)
        }
        var best: (band: PageBand, dist: CGFloat, edge: PageEdge)?
        for band in bands {
            let hit: (dist: CGFloat, edge: PageEdge)?
            if pointY < band.minY {
                hit = (band.minY - pointY, .top)      // above page → its beginning
            } else if pointY >= band.maxY {
                hit = (pointY - band.maxY, .bottom)    // below page → its end
            } else {
                hit = nil
            }
            if let hit, best == nil || hit.dist < best!.dist {
                best = (band, hit.dist, hit.edge)
            }
        }
        guard let best else { return nil }
        return (best.band, best.edge)
    }
}

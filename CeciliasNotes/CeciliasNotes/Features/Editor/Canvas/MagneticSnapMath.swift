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

    // MARK: - Palette reservation (zoom / centring)

    /// How much of the tool-palette strip to reserve inside the scroll
    /// view's content inset.
    ///
    /// Reserve the strip ONLY while the page is narrower than the
    /// viewport (`trueCentreGutter > 0`) — there is a real centred
    /// resting position to protect from the palette. Once the user
    /// zooms IN far enough that the page overflows the viewport
    /// (`trueCentreGutter <= 0`), the palette just floats over the
    /// content and the reservation must drop to 0 so the page can
    /// scroll flush to either edge. A non-zero reservation there both
    /// stopped the page reaching the viewport edge ("won't stick to
    /// the edges when zooming in") and, sitting on one side only,
    /// shifted the overflowing page off-centre ("skewed to the left").
    static func paletteReservation(paletteStrip: CGFloat, trueCentreGutter: CGFloat) -> CGFloat {
        guard trueCentreGutter > 0 else { return 0 }
        return max(0, paletteStrip - trueCentreGutter)
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

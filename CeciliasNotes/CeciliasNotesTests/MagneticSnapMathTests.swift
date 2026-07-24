import XCTest
import CoreGraphics
@testable import CeciliasNotes

/// Covers the pure geometry behind the editor's "magnetic" feel —
/// the two device-reported bugs fixed alongside these tests:
///
///  • Cross-page image drag that landed in the gutter BETWEEN two
///    pages used to revert the image to its origin. It must now snap
///    to the nearest page edge (end of the current page / beginning
///    of the next).
///  • Zooming a page IN past the viewport width used to keep the
///    tool-palette strip reserved in the content inset, so the page
///    could not scroll flush to the edges and leaned left. The
///    reservation must drop to 0 once the page overflows the viewport.
final class MagneticSnapMathTests: XCTestCase {

    // MARK: - Palette reservation (zoom / centring)

    func test_paletteReservation_pageNarrowerThanViewport_reservesTaperedStrip() {
        // Gutter smaller than the strip → reserve the remainder so the
        // page clears the palette but isn't shoved further than needed.
        let r = MagneticSnapMath.paletteReservation(paletteStrip: 68, trueCentreGutter: 20)
        XCTAssertEqual(r, 48, accuracy: 0.0001)
    }

    func test_paletteReservation_wideGutter_reservesNothing() {
        // Gutter already clears the palette → no reservation, page
        // stays truly centred.
        let r = MagneticSnapMath.paletteReservation(paletteStrip: 68, trueCentreGutter: 120)
        XCTAssertEqual(r, 0, accuracy: 0.0001)
    }

    func test_paletteReservation_zoomedInPageOverflows_reservesNothing() {
        // trueCentreGutter <= 0 means the page is WIDER than the
        // viewport (zoomed in). Reservation must be 0 so the page can
        // scroll flush to the edges and stay centred — the regression.
        XCTAssertEqual(MagneticSnapMath.paletteReservation(paletteStrip: 68, trueCentreGutter: 0), 0)
        XCTAssertEqual(MagneticSnapMath.paletteReservation(paletteStrip: 68, trueCentreGutter: -140), 0)
    }

    // MARK: - Cross-page hand-off resolution

    /// Three stacked A4-ish pages with a 40pt inter-page gutter.
    private var threePages: [MagneticSnapMath.PageBand] {
        [
            .init(index: 0, minY: 0,    maxY: 1000),
            .init(index: 1, minY: 1040, maxY: 2040),
            .init(index: 2, minY: 2080, maxY: 3080),
        ]
    }

    func test_resolveCrossPage_insidePage_returnsThatPageNoSnap() {
        let r = MagneticSnapMath.resolveCrossPage(pointY: 1500, bands: threePages)
        XCTAssertEqual(r?.band.index, 1)
        XCTAssertNil(r?.edge, "A drop inside a page keeps the free in-page fraction")
    }

    func test_resolveCrossPage_gutterNearerLowerPage_snapsToNextBeginning() {
        // Point at 1030 sits in the gutter (1000…1040), 30pt below
        // page 0's end and 10pt above page 1's beginning → nearer the
        // beginning of page 1.
        let r = MagneticSnapMath.resolveCrossPage(pointY: 1030, bands: threePages)
        XCTAssertEqual(r?.band.index, 1)
        XCTAssertEqual(r?.edge, .top, "Nearest edge is the next page's beginning")
    }

    func test_resolveCrossPage_gutterNearerUpperPage_snapsToCurrentEnd() {
        // Point at 1010 sits in the gutter, 10pt below page 0's end and
        // 30pt above page 1 → nearer the END of page 0.
        let r = MagneticSnapMath.resolveCrossPage(pointY: 1010, bands: threePages)
        XCTAssertEqual(r?.band.index, 0)
        XCTAssertEqual(r?.edge, .bottom, "Nearest edge is the current page's end")
    }

    func test_resolveCrossPage_droppedAboveFirstPage_snapsToFirstBeginning() {
        let r = MagneticSnapMath.resolveCrossPage(pointY: -500, bands: threePages)
        XCTAssertEqual(r?.band.index, 0)
        XCTAssertEqual(r?.edge, .top)
    }

    func test_resolveCrossPage_droppedBelowLastPage_snapsToLastEnd() {
        // Past the bottom of the whole document → stick to the end of
        // the last page rather than reverting to origin.
        let r = MagneticSnapMath.resolveCrossPage(pointY: 5000, bands: threePages)
        XCTAssertEqual(r?.band.index, 2)
        XCTAssertEqual(r?.edge, .bottom)
    }

    func test_resolveCrossPage_noBands_returnsNil() {
        XCTAssertNil(MagneticSnapMath.resolveCrossPage(pointY: 100, bands: []))
    }
}

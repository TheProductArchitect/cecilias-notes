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

    // MARK: - Horizontal centring (across screen sizes)

    private let a4Width: CGFloat = 595   // PageSize.a4.pointSize.width

    func test_centering_iPadLandscape_centresWithSymmetricMargins() throws {
        // iPad Pro 11" landscape ≈ 1194pt; A4 page at 1× fits.
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 1194, contentWidth: a4Width, zoomScale: 1)
        XCTAssertEqual(c.inset, (1194 - 595) / 2, accuracy: 0.01)
        // Centred offset is -inset — NOT 0 (0 would glue it to the left).
        XCTAssertEqual(try XCTUnwrap(c.centeredOffsetX), -(1194 - 595) / 2, accuracy: 0.01,
                       "must pin the centred offset, not leave it at 0")
    }

    func test_centering_iPadPortrait_centres() throws {
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 834, contentWidth: a4Width, zoomScale: 1)
        XCTAssertEqual(c.inset, (834 - 595) / 2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(c.centeredOffsetX), -(834 - 595) / 2, accuracy: 0.01)
    }

    func test_centering_iPhoneFitToWidth_centres() {
        // iPhone ≈ 390pt; A4 fit ≈ 0.62 → displayed ≈ 369 < 390, fits.
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 390, contentWidth: a4Width, zoomScale: 0.62)
        let displayed = a4Width * 0.62
        XCTAssertEqual(c.inset, (390 - displayed) / 2, accuracy: 0.01)
        XCTAssertNotNil(c.centeredOffsetX)
    }

    func test_centering_zoomedInPastViewport_noInsetNoPin() {
        // Zoomed to 2.5× on iPad: displayed 1487 > 1194 → page overflows,
        // pans freely: no inset, no forced offset.
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 1194, contentWidth: a4Width, zoomScale: 2.5)
        XCTAssertEqual(c.inset, 0)
        XCTAssertNil(c.centeredOffsetX, "an overflowing page has no single centred offset — it pans")
    }

    func test_centering_narrowSplitView_pageWiderThanViewport_pans() {
        // iPad narrow split view ≈ 320pt < A4 595 at 1× → overflows.
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 320, contentWidth: a4Width, zoomScale: 1)
        XCTAssertEqual(c.inset, 0)
        XCTAssertNil(c.centeredOffsetX)
    }

    func test_centering_exactFit_pinsToZeroInset() throws {
        // Displayed width == bounds → inset 0, centred offset 0 (flush).
        let c = MagneticSnapMath.horizontalCentering(boundsWidth: 595, contentWidth: a4Width, zoomScale: 1)
        XCTAssertEqual(c.inset, 0)
        XCTAssertEqual(try XCTUnwrap(c.centeredOffsetX), 0, accuracy: 0.01)
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

import SwiftUI
import XCTest
@testable import CeciliasNotes

/// Unit tests for `ShapeKindPath` — the pure path generators backing
/// the shapes tool. We can't structurally diff a SwiftUI `Path`, but
/// we can verify the bounding box stays inside the requested rect
/// (within a tiny tolerance for curved shapes whose control points
/// can briefly leave the box), and that every kind produces a
/// non-empty path.
@MainActor
final class ShapeKindPathTests: XCTestCase {

    private let testRect = CGRect(x: 100, y: 100, width: 200, height: 120)

    /// Every kind produces a non-empty path when given a non-zero rect.
    func test_allKinds_produceNonEmptyPath() {
        for kind in ShapeKind.allCases {
            let path = ShapeKindPath.path(for: kind, in: testRect)
            XCTAssertFalse(
                path.isEmpty,
                "Path for \(kind) was empty"
            )
        }
    }

    /// Primitive kinds (rectangle / rounded rect / ellipse / triangle /
    /// line / arrow) must stay strictly inside the requested rect.
    /// Decorative kinds (heart / callout) use curves whose control
    /// points may briefly exit the box; we relax the bound check for
    /// those via the tolerance below.
    func test_primitives_stayInsideRequestedRect() {
        let primitives: [ShapeKind] = [
            .rectangle, .roundedRectangle, .ellipse,
            .triangle, .line, .arrow, .star
        ]
        for kind in primitives {
            let path = ShapeKindPath.path(for: kind, in: testRect)
            let bbox = path.boundingRect
            XCTAssertGreaterThanOrEqual(
                bbox.minX, testRect.minX - 1,
                "\(kind) extends left of rect: \(bbox) vs \(testRect)"
            )
            XCTAssertLessThanOrEqual(
                bbox.maxX, testRect.maxX + 1,
                "\(kind) extends right of rect: \(bbox) vs \(testRect)"
            )
            XCTAssertGreaterThanOrEqual(
                bbox.minY, testRect.minY - 1,
                "\(kind) extends above rect: \(bbox) vs \(testRect)"
            )
            XCTAssertLessThanOrEqual(
                bbox.maxY, testRect.maxY + 1,
                "\(kind) extends below rect: \(bbox) vs \(testRect)"
            )
        }
    }

    /// Heart and callout use bezier curves whose envelopes can extend
    /// well beyond the rect (Path.boundingRect is the conservative
    /// control-point hull, not the visible-stroke hull). The strict
    /// "stays inside" check doesn't apply; instead we verify the path
    /// is anchored within the caller's rect rather than drawn at the
    /// origin — gross drift would catch a path-generation bug like
    /// forgetting to translate by rect.origin.
    func test_decoratives_areAnchoredNearRect() {
        for kind in [ShapeKind.heart, .callout] {
            let path = ShapeKindPath.path(for: kind, in: testRect)
            let bbox = path.boundingRect
            // The path should overlap the rect substantially —
            // intersection area at least 25% of either bbox.
            let intersection = bbox.intersection(testRect)
            let overlap = intersection.width * intersection.height
            let bboxArea = max(bbox.width * bbox.height, 1)
            let rectArea = max(testRect.width * testRect.height, 1)
            let overlapRatio = overlap / min(bboxArea, rectArea)
            XCTAssertGreaterThan(
                overlapRatio, 0.25,
                "\(kind) doesn't overlap requested rect — likely drawn at origin"
            )
        }
    }

    /// A zero-size rect shouldn't crash any kind. Returned paths can
    /// be degenerate (empty bbox) but the call must complete.
    func test_zeroSizeRect_doesNotCrash() {
        let zero = CGRect(x: 50, y: 50, width: 0, height: 0)
        for kind in ShapeKind.allCases {
            _ = ShapeKindPath.path(for: kind, in: zero)
        }
    }

    /// Category mapping must be exhaustive — every ShapeKind belongs
    /// to exactly one category. Guards a future case from sneaking in
    /// without picker UI placement.
    func test_categoryMapping_exhaustive() {
        let primitives = ShapeKind.allCases.filter { $0.category == .primitive }
        let decoratives = ShapeKind.allCases.filter { $0.category == .decorative }
        XCTAssertEqual(
            primitives.count + decoratives.count,
            ShapeKind.allCases.count
        )
        XCTAssertFalse(primitives.isEmpty, "primitive category empty")
        XCTAssertFalse(decoratives.isEmpty, "decorative category empty")
    }
}

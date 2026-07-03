import CoreGraphics
import XCTest
@testable import CeciliasNotes

/// Unit coverage for `LassoMath.convexHull` — the geometry behind
/// the freeform lasso's hugging selection outline. Pure function,
/// no fixtures needed.
@MainActor
final class LassoConvexHullTests: XCTestCase {

    func test_fewerThanThreePoints_returnsEmpty() {
        XCTAssertTrue(LassoMath.convexHull([]).isEmpty)
        XCTAssertTrue(LassoMath.convexHull([CGPoint(x: 1, y: 1)]).isEmpty)
        XCTAssertTrue(LassoMath.convexHull([
            CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5)
        ]).isEmpty)
    }

    func test_collinearPoints_returnEmpty() {
        // A degenerate (zero-area) cloud can't form a polygon — the
        // chrome must fall back to the rectangle.
        let hull = LassoMath.convexHull([
            CGPoint(x: 0, y: 0),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 2, y: 2),
            CGPoint(x: 3, y: 3),
        ])
        XCTAssertTrue(hull.isEmpty)
    }

    func test_triangle_returnsAllThreeVertices() {
        let pts = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0),
            CGPoint(x: 5, y: 8),
        ]
        let hull = LassoMath.convexHull(pts)
        XCTAssertEqual(hull.count, 3)
        for p in pts {
            XCTAssertTrue(hull.contains(p), "hull must contain vertex \(p)")
        }
    }

    func test_interiorPointsAreExcluded() {
        // Square with a cluster of points inside — the hull is just
        // the four corners.
        var pts = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 100, y: 0),
            CGPoint(x: 100, y: 100),
            CGPoint(x: 0, y: 100),
        ]
        pts += [
            CGPoint(x: 50, y: 50),
            CGPoint(x: 20, y: 70),
            CGPoint(x: 80, y: 30),
        ]
        let hull = LassoMath.convexHull(pts)
        XCTAssertEqual(hull.count, 4)
        XCTAssertFalse(hull.contains(CGPoint(x: 50, y: 50)))
    }

    func test_duplicatePoints_dontBreakTheHull() {
        let pts = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0),
            CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 0),
            CGPoint(x: 5, y: 8),
        ]
        let hull = LassoMath.convexHull(pts)
        XCTAssertEqual(hull.count, 3)
    }

    func test_hullContainsEveryInputPoint() {
        // Property check on a deterministic pseudo-random cloud:
        // every input point must be inside (or on) the hull polygon.
        var seed: UInt64 = 0x5EED
        func next() -> CGFloat {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return CGFloat(seed >> 33) / CGFloat(UInt32.max) * 200
        }
        let pts = (0..<60).map { _ in CGPoint(x: next(), y: next()) }
        let hull = LassoMath.convexHull(pts)
        XCTAssertGreaterThanOrEqual(hull.count, 3)

        let path = CGMutablePath()
        path.move(to: hull[0])
        for p in hull.dropFirst() { path.addLine(to: p) }
        path.closeSubpath()
        // Inset test point slightly toward the centroid to dodge
        // exact-boundary FP ambiguity.
        let cx = pts.map(\.x).reduce(0, +) / CGFloat(pts.count)
        let cy = pts.map(\.y).reduce(0, +) / CGFloat(pts.count)
        for p in pts {
            let nudged = CGPoint(x: p.x + (cx - p.x) * 0.001,
                                 y: p.y + (cy - p.y) * 0.001)
            XCTAssertTrue(
                path.contains(nudged),
                "input point \(p) fell outside the hull"
            )
        }
    }
}

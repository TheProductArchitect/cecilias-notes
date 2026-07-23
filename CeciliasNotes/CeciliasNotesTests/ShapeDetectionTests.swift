import XCTest
import PencilKit
@testable import CeciliasNotes

/// Vision-based shape recognition. Constructs `PKStroke` instances
/// programmatically — sample point arrays for known shapes — and runs
/// them through `ShapeRecognizer.recognize(_:)`. Each call goes through
/// CoreGraphics rasterisation + `VNDetectContoursRequest`, so allow
/// generous timing budgets in CI.
///
/// Squiggle classification is intentionally negative-tested: a path
/// that isn't a recognisable shape must yield `nil`, not a misfire.
@MainActor
final class ShapeDetectionTests: XCTestCase {

    // MARK: Stroke factories

    /// Construct a closed PKStroke from a sequence of (x, y) points.
    private func makeStroke(_ points: [CGPoint]) -> PKStroke {
        let now = Date()
        let pkPoints = points.enumerated().map { i, p in
            PKStrokePoint(
                location: p,
                timeOffset: Double(i) * 0.01,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 0.5,
                azimuth: 0,
                altitude: .pi / 2
            )
        }
        let path = PKStrokePath(controlPoints: pkPoints, creationDate: now)
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    /// Closed rectangle. The stroke starts and ends MID-EDGE rather
    /// than at a corner. PKStrokePath's Catmull-Rom interpolation
    /// blurs the seam into a tiny curve; if the seam lands on a corner
    /// the curve becomes a 5th vertex. Starting in the middle of the
    /// top edge keeps the seam on a straight stretch where the
    /// distortion is invisible to Vision's polygon approximator.
    private func roughRectangleStroke() -> PKStroke {
        var pts: [CGPoint] = []
        let rect = CGRect(x: 100, y: 100, width: 200, height: 120)
        let stepsPerEdge = 20
        // Start at the midpoint of the top edge (x=200), go right.
        // top-half (mid → top-right corner)
        for i in 0...(stepsPerEdge / 2) {
            let t = CGFloat(i) / CGFloat(stepsPerEdge)
            pts.append(CGPoint(x: rect.midX + t * rect.width, y: rect.minY))
        }
        // right edge
        for i in 1...stepsPerEdge {
            let t = CGFloat(i) / CGFloat(stepsPerEdge)
            pts.append(CGPoint(x: rect.maxX, y: rect.minY + t * rect.height))
        }
        // bottom edge
        for i in 1...stepsPerEdge {
            let t = CGFloat(i) / CGFloat(stepsPerEdge)
            pts.append(CGPoint(x: rect.maxX - t * rect.width, y: rect.maxY))
        }
        // left edge
        for i in 1...stepsPerEdge {
            let t = CGFloat(i) / CGFloat(stepsPerEdge)
            pts.append(CGPoint(x: rect.minX, y: rect.maxY - t * rect.height))
        }
        // top-half (top-left corner → mid)
        for i in 1...(stepsPerEdge / 2) {
            let t = CGFloat(i) / CGFloat(stepsPerEdge)
            pts.append(CGPoint(x: rect.minX + t * rect.width, y: rect.minY))
        }
        return makeStroke(pts)
    }

    /// Sample a near-perfect circle.
    private func circleStroke() -> PKStroke {
        let centre = CGPoint(x: 200, y: 200)
        let radius: CGFloat = 80
        var pts: [CGPoint] = []
        let n = 64
        for i in 0...n {
            let a = CGFloat(i) / CGFloat(n) * 2 * .pi
            pts.append(CGPoint(x: centre.x + radius * cos(a),
                               y: centre.y + radius * sin(a)))
        }
        return makeStroke(pts)
    }

    /// "U"-shaped open path — clearly not a line (too curvy), clearly
    /// not closed (endpoints span 200pt horizontally with no segment
    /// connecting them), and not a polygon Vision would recognise via
    /// closed-contour detection. The recogniser's `isClosed` check
    /// uses end-gap relative to path length; this fixture has
    /// endGap/pathLen ≈ 0.5, comfortably above the 0.18 closed
    /// threshold so the open-stroke path runs and only line/arrow
    /// detection is attempted. Line fit fails because the U-bottom
    /// pulls the residual far above the line tolerance.
    private func squiggleStroke() -> PKStroke {
        var pts: [CGPoint] = []
        // Down stroke: x=100, y 200→300
        for i in 0...10 {
            let t = CGFloat(i) / 10
            pts.append(CGPoint(x: 100, y: 200 + t * 100))
        }
        // Across: y=300, x 100→300
        for i in 1...20 {
            let t = CGFloat(i) / 20
            pts.append(CGPoint(x: 100 + t * 200, y: 300))
        }
        // Up stroke: x=300, y 300→200
        for i in 1...10 {
            let t = CGFloat(i) / 10
            pts.append(CGPoint(x: 300, y: 300 - t * 100))
        }
        return makeStroke(pts)
    }

    // MARK: Tests

    func test_recogniseRectangle_isNotConverted() async {
        // `ShapeRecognizer.recognize` intentionally accepts only lines
        // and near-circular closed strokes — rectangle conversion was
        // removed as unreliable in the wild (see ShapeRecognizer.swift).
        let stroke = roughRectangleStroke()
        let result = await ShapeRecognizer.recognize(stroke)
        XCTAssertNil(
            result,
            "Rectangle auto-conversion is disabled; got \(String(describing: result))"
        )
    }

    func test_recogniseCircle() async {
        let stroke = circleStroke()
        let result = await ShapeRecognizer.recognize(stroke)
        switch result {
        case .circle, .ellipse:
            // A perfect-aspect circle should classify as circle, but
            // ellipse is the wider parent and acceptable as a fallback.
            break
        default:
            XCTFail("Expected circle/ellipse, got \(String(describing: result))")
        }
    }

    // MARK: - Handwriting protection (the "my writing gets undone" bug)
    //
    // Shape Assist runs after EVERY drawing-tool stroke. Handwriting is
    // full of geometric strokes — an `l`/dash is a line, an `o` is a
    // circle — and with the old 4pt/24pt gates letters were converted
    // into clean geometry 600ms after pen-lift, which users reported as
    // "anything I write gets undone after a few strokes." These pin the
    // size floor: letter-scale strokes must NEVER convert; deliberate
    // diagram-scale shapes still must.

    func test_letterSizedVerticalStroke_isNotConverted() async {
        // A handwritten `l`: ~28pt tall, near-straight.
        let pts = (0...20).map { i in
            CGPoint(x: 100 + CGFloat(i % 3) * 0.6, y: 100 + CGFloat(i) * 1.4)
        }
        let shape = await ShapeRecognizer.recognize(makeStroke(pts))
        XCTAssertNil(shape, "a letter-sized stroke (~28pt) must never become a line")
    }

    func test_letterSizedO_isNotConverted() async {
        // A handwritten `o`: ~20pt circle.
        let pts = (0...32).map { i -> CGPoint in
            let a = CGFloat(i) / 32 * 2 * .pi
            return CGPoint(x: 200 + 10 * cos(a), y: 200 + 10 * sin(a))
        }
        let shape = await ShapeRecognizer.recognize(makeStroke(pts))
        XCTAssertNil(shape, "a letter-sized `o` (~20pt) must never become a circle")
    }

    func test_deliberateLongLine_isStillConverted() async {
        // A deliberate ruler-scale diagonal line: 160pt wide × 80pt
        // tall (~179pt long) — comfortably past minLineLength and the
        // pre-existing bbox.height > 4 flat-stroke guard.
        let pts = (0...40).map { i -> CGPoint in
            let t = CGFloat(i) / 40
            return CGPoint(x: 100 + t * 160, y: 300 + t * 80)
        }
        let shape = await ShapeRecognizer.recognize(makeStroke(pts))
        XCTAssertNotNil(shape, "a deliberate ~179pt line must still convert")
        if case .line = shape {} else {
            XCTFail("expected .line, got \(String(describing: shape))")
        }
    }

    func test_squiggleIsNotRecognised() async {
        let stroke = squiggleStroke()
        let result = await ShapeRecognizer.recognize(stroke)
        XCTAssertNil(
            result,
            "Squiggle should not classify as a shape, but got \(String(describing: result))"
        )
    }
}

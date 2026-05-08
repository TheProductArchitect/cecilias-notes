import Foundation
import PencilKit
import CoreGraphics
import UIKit
import Vision

// MARK: - RecognizedShape

/// What `ShapeRecognizer` produces when it's confident.
///
/// Polygons (triangle / pentagon / hexagon) carry their resolved vertices
/// rather than a bbox so non-axis-aligned drawings produce a clean shape
/// at the same orientation. Square/Circle are kept distinct from
/// rectangle/ellipse so callers can show "Square recognised" rather than
/// the user-confusing "Rectangle" when they drew an obvious square.
enum RecognizedShape {
    case line(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case square(rect: CGRect)
    case ellipse(rect: CGRect)
    case circle(rect: CGRect)
    case triangle(a: CGPoint, b: CGPoint, c: CGPoint)
    case pentagon(points: [CGPoint])
    case hexagon(points: [CGPoint])
    case arrow(start: CGPoint, tip: CGPoint, leftBarb: CGPoint, rightBarb: CGPoint)
}

// MARK: - ShapeRecognizer

/// Vision-based shape detector. Rasterises the user's stroke into a small
/// alpha mask, runs `VNDetectContoursRequest`, and classifies the result
/// using `VNContour.polygonApproximation(epsilon:)`. Arrows are detected
/// by stroke-endpoint geometry — Vision contours don't model the open
/// arrowhead well.
///
/// Performance: rasterise + detect runs ~30–80 ms on modern iPad. Always
/// call `recognize` from a background `Task` — it does not hop to the
/// main actor itself.
enum ShapeRecognizer {

    /// Confidence threshold for stroke → shape replacement.
    /// Lowered from 0.75 → 0.65 so more borderline shapes get caught;
    /// the more-prominent 5s "Undo Shape" pill makes false positives
    /// trivially recoverable.
    static let confidenceThreshold: CGFloat = 0.65

    /// Polygon approximation tolerance — fraction of the contour's
    /// arclength. `0.04` is loose enough to swallow rounded rectangle
    /// corners while still distinguishing a hexagon from a circle.
    static let polygonEpsilon: Float = 0.04

    /// Resolve a shape from the stroke, or `nil` if no candidate clears
    /// the confidence bar. Async so the heavy lifting (Vision request,
    /// rasterisation) can run off the main actor.
    static func recognize(_ stroke: PKStroke) async -> RecognizedShape? {
        let points = sample(stroke, count: 96)
        guard points.count >= 16 else { return nil }

        let bbox = boundingBox(points)
        guard bbox.width > 4, bbox.height > 4 else { return nil }

        let pathLength = perimeter(points)
        guard pathLength > 24 else { return nil }

        let endGap   = distance(points.first ?? .zero, points.last ?? .zero)
        let isClosed = endGap < pathLength * 0.18

        // 1. Open strokes — try arrow first, then line.
        if !isClosed {
            if let arrow = detectArrow(points: points, pathLength: pathLength) {
                return arrow
            }
            if let line = scoreLine(points: points), line.confidence >= confidenceThreshold {
                return line.shape
            }
            return nil
        }

        // 2. Closed strokes — Vision contour + polygon approximation.
        guard let cgImage = rasterise(points: points, bbox: bbox) else { return nil }
        guard let normalisedVertices = await detectPolygon(in: cgImage) else { return nil }
        guard normalisedVertices.count >= 3 else { return nil }

        let canvasVertices = normalisedVertices.map { remap($0, bbox: bbox, image: cgImage) }
        let n = canvasVertices.count

        // Confidence here is binary-ish — we passed Vision's detection AND
        // landed on a recognised vertex count. Keep the literal at 0.85 so
        // an obvious shape wins easily over the line/arrow score path.
        let confidence: CGFloat = 0.85
        guard confidence >= confidenceThreshold else { return nil }

        switch n {
        case 3:
            return .triangle(a: canvasVertices[0],
                             b: canvasVertices[1],
                             c: canvasVertices[2])
        case 4:
            return classifyQuad(canvasVertices, bbox: bbox)
        case 5:
            return .pentagon(points: canvasVertices)
        case 6:
            return .hexagon(points: canvasVertices)
        default:
            // Lots of vertices → rounded curve. Distinguish circle vs
            // ellipse by aspect ratio of the original bbox.
            let aspect = bbox.width / bbox.height
            if abs(aspect - 1) < 0.18 {
                let side = (bbox.width + bbox.height) / 2
                let centred = CGRect(
                    x: bbox.midX - side / 2,
                    y: bbox.midY - side / 2,
                    width: side, height: side
                )
                return .circle(rect: centred)
            }
            return .ellipse(rect: bbox)
        }
    }

    // MARK: - Sampling

    private static func sample(_ stroke: PKStroke, count: Int) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 0 else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        let last = CGFloat(path.count - 1)
        for i in 0..<count {
            let t = CGFloat(i) / CGFloat(max(1, count - 1)) * last
            out.append(path.interpolatedLocation(at: t))
        }
        return out
    }

    // MARK: - Geometry helpers

    private static func boundingBox(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private static func perimeter(_ pts: [CGPoint]) -> CGFloat {
        var sum: CGFloat = 0
        for i in 1..<pts.count { sum += distance(pts[i - 1], pts[i]) }
        return sum
    }

    /// Signed angular delta in `(-π, π]`.
    private static func angleDelta(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        var d = b - a
        while d >  .pi { d -= 2 * .pi }
        while d <= -.pi { d += 2 * .pi }
        return d
    }

    /// Mirror `p` across the line through `a → b`.
    private static func mirror(_ p: CGPoint, across a: CGPoint, _ b: CGPoint) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0.0001 else { return p }
        let t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return CGPoint(x: 2 * projX - p.x, y: 2 * projY - p.y)
    }

    // MARK: - Line scoring (open strokes)

    private static func scoreLine(points: [CGPoint]) -> (shape: RecognizedShape, confidence: CGFloat)? {
        guard let first = points.first, let last = points.last else { return nil }
        let dx = last.x - first.x
        let dy = last.y - first.y
        let len = hypot(dx, dy)
        guard len > 1 else { return nil }
        var sum: CGFloat = 0
        for p in points {
            sum += abs((p.x - first.x) * dy - (p.y - first.y) * dx) / len
        }
        let residual = sum / CGFloat(points.count)
        let confidence = (1 - residual / max(20, len * 0.15)).clampedShape()
        return (.line(start: first, end: last), confidence)
    }

    // MARK: - Arrow detection (heuristic, endpoint analysis)

    /// Drawn arrows usually trace `start → tip → barb` in one stroke
    /// (lifting the pen for a second barb is the exception). We detect
    /// the kink: a sharp angle late in the stroke where the pen reverses
    /// direction. The mirror across the body line gives the second
    /// barb so the rendered arrow looks symmetrical.
    private static func detectArrow(points: [CGPoint], pathLength: CGFloat) -> RecognizedShape? {
        guard points.count >= 24, let start = points.first, let end = points.last else { return nil }

        // Find the point farthest from the start — candidate "tip".
        var tipIdx = points.count - 1
        var tipDist: CGFloat = 0
        for (i, p) in points.enumerated() {
            let d = distance(p, start)
            if d > tipDist { tipDist = d; tipIdx = i }
        }
        // Tip must lie comfortably inside the stroke (not at start, not at end).
        guard tipIdx > points.count * 6 / 10, tipIdx < points.count - 4 else { return nil }
        let tip = points[tipIdx]

        let bodyLen = distance(start, tip)
        let barbLen = distance(tip, end)
        // Barb segment must be substantially shorter than the body — otherwise
        // we'd be mistaking a bent line for an arrow.
        guard barbLen > 6,
              barbLen < bodyLen * 0.6,
              bodyLen > 24
        else { return nil }

        // Body should be roughly straight. Reject if the leading 80% of
        // the stroke deviates a lot from the start→tip chord.
        let bodyPoints = Array(points.prefix(tipIdx + 1))
        guard let bodyFit = scoreLine(points: bodyPoints), bodyFit.confidence > 0.55 else { return nil }

        let bodyAngle = atan2(tip.y - start.y, tip.x - start.x)
        let barbAngle = atan2(end.y - tip.y, end.x - tip.x)
        let delta     = abs(angleDelta(bodyAngle, barbAngle))
        // Reject head-on continuations (delta near 0) and full reversals
        // (delta near π). Real arrows kink ~30°–150°.
        guard delta > .pi / 6, delta < .pi * 5 / 6 else { return nil }

        let leftBarb  = end
        let rightBarb = mirror(end, across: start, tip)
        return .arrow(start: start, tip: tip, leftBarb: leftBarb, rightBarb: rightBarb)
    }

    // MARK: - Vision rasterisation

    /// Rasterise the closed stroke into a 256×256 alpha mask: white shape
    /// on black, padded so the contour doesn't touch the edge (Vision
    /// otherwise rejects edge-coincident contours).
    private static func rasterise(points: [CGPoint], bbox: CGRect) -> CGImage? {
        let imageSize = CGSize(width: 256, height: 256)
        let padding: CGFloat = 16

        let scaleX = (imageSize.width  - 2 * padding) / max(1, bbox.width)
        let scaleY = (imageSize.height - 2 * padding) / max(1, bbox.height)
        let scale  = Swift.min(scaleX, scaleY)
        let dx = (imageSize.width  - bbox.width  * scale) / 2 - bbox.minX * scale
        let dy = (imageSize.height - bbox.height * scale) / 2 - bbox.minY * scale

        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let image = renderer.image { ctx in
            UIColor.black.setFill()
            ctx.fill(CGRect(origin: .zero, size: imageSize))

            let path = UIBezierPath()
            for (i, p) in points.enumerated() {
                let pt = CGPoint(x: p.x * scale + dx, y: p.y * scale + dy)
                if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
            }
            path.close()
            UIColor.white.setFill()
            path.fill()
        }
        return image.cgImage
    }

    /// Run Vision contour detection + polygon approximation. Returns
    /// the polygon's vertices in Vision's normalised coordinate space
    /// (origin bottom-left, y up, range `[0, 1]`).
    private static func detectPolygon(in cgImage: CGImage) async -> [CGPoint]? {
        await withCheckedContinuation { (continuation: CheckedContinuation<[CGPoint]?, Never>) in
            let request = VNDetectContoursRequest { request, _ in
                guard let observation = request.results?.first as? VNContoursObservation else {
                    continuation.resume(returning: nil); return
                }
                // Largest top-level contour by point count = the user's stroke.
                var best: VNContour?
                for contour in observation.topLevelContours {
                    if (best?.pointCount ?? 0) < contour.pointCount { best = contour }
                }
                guard let contour = best,
                      let approx  = try? contour.polygonApproximation(epsilon: polygonEpsilon)
                else {
                    continuation.resume(returning: nil); return
                }
                let pts = approx.normalizedPoints.map {
                    CGPoint(x: CGFloat($0.x), y: CGFloat($0.y))
                }
                continuation.resume(returning: pts)
            }
            request.contrastAdjustment = 1.0
            request.detectsDarkOnLight = false  // white shape on black

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request]) }
            catch { continuation.resume(returning: nil) }
        }
    }

    /// Map a Vision-normalised point back into canvas coords. We applied
    /// uniform scale + centring during rasterisation; reverse it here.
    /// Vision's y-axis is flipped (origin bottom-left), so y is inverted.
    private static func remap(_ p: CGPoint, bbox: CGRect, image: CGImage) -> CGPoint {
        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let padding: CGFloat = 16
        let scaleX = (imageW - 2 * padding) / max(1, bbox.width)
        let scaleY = (imageH - 2 * padding) / max(1, bbox.height)
        let scale  = Swift.min(scaleX, scaleY)
        let dx = (imageW - bbox.width  * scale) / 2 - bbox.minX * scale
        let dy = (imageH - bbox.height * scale) / 2 - bbox.minY * scale
        // Vision normalised → image coords (flip y).
        let imgX = p.x * imageW
        let imgY = (1 - p.y) * imageH
        return CGPoint(x: (imgX - dx) / scale, y: (imgY - dy) / scale)
    }

    // MARK: - Quadrilateral classification

    /// Decide square vs rectangle from four contour vertices. We snap to
    /// an axis-aligned bbox of the corners — free-rotated rectangles are
    /// a stretch goal — and call it a square when its sides agree
    /// within ~12%.
    private static func classifyQuad(_ vertices: [CGPoint], bbox: CGRect) -> RecognizedShape {
        let cornerBox = boundingBox(vertices)
        let aspect = cornerBox.width / max(0.0001, cornerBox.height)
        if abs(aspect - 1) < 0.18 {
            let side = (cornerBox.width + cornerBox.height) / 2
            return .square(rect: CGRect(
                x: cornerBox.midX - side / 2,
                y: cornerBox.midY - side / 2,
                width: side, height: side
            ))
        }
        return .rectangle(rect: cornerBox)
    }
}

// MARK: - Local clamp helper

private extension CGFloat {
    func clampedShape() -> CGFloat { Swift.max(0, Swift.min(1, self)) }
}

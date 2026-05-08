import Foundation
import PencilKit
import CoreGraphics

// MARK: - RecognizedShape

/// What `ShapeRecognizer` produces when it's confident.
enum RecognizedShape {
    case line(start: CGPoint, end: CGPoint)
    case rectangle(rect: CGRect)
    case ellipse(rect: CGRect)
    case triangle(a: CGPoint, b: CGPoint, c: CGPoint)
}

// MARK: - ShapeRecognizer

/// Geometric-heuristic shape detector. No machine learning, no Vision —
/// just samples the stroke, fits candidate shapes, picks the best fit
/// above a confidence threshold.
///
/// Confidence is `1 - (residual / pathLength)` clamped to `[0, 1]`.
/// Threshold for replacement is `0.75` (per spec).
enum ShapeRecognizer {

    /// Confidence threshold for stroke → shape replacement.
    static let confidenceThreshold: CGFloat = 0.75

    /// Detect a shape in `stroke`, or return nil if none qualifies.
    /// Strokes shorter than 8 sample points are ignored (likely a tap or scribble).
    static func recognize(_ stroke: PKStroke) -> RecognizedShape? {
        let points = sample(stroke, count: 64)
        guard points.count >= 8 else { return nil }

        let bbox = boundingBox(points)
        // Reject degenerate strokes (zero-area boxes).
        guard bbox.width > 4, bbox.height > 4 else { return nil }

        let pathLength = perimeter(points)
        guard pathLength > 20 else { return nil }

        let endGap = distance(points.first ?? .zero, points.last ?? .zero)
        let isClosed = endGap < pathLength * 0.18

        // Score each candidate. Higher is better.
        var candidates: [(shape: RecognizedShape, confidence: CGFloat)] = []

        if isClosed {
            // Closed → ellipse or polygon.
            if let s = scoreEllipse(points: points, bbox: bbox, pathLength: pathLength) {
                candidates.append(s)
            }
            if let s = scorePolygon(points: points, sides: 3, pathLength: pathLength) {
                candidates.append(s)
            }
            if let s = scorePolygon(points: points, sides: 4, pathLength: pathLength) {
                candidates.append(s)
            }
        } else {
            // Open → line.
            if let s = scoreLine(points: points, pathLength: pathLength) {
                candidates.append(s)
            }
        }

        guard let best = candidates.max(by: { $0.confidence < $1.confidence }),
              best.confidence >= confidenceThreshold
        else { return nil }
        return best.shape
    }

    // MARK: - Sampling

    /// Resample `count` evenly-spaced points along the stroke's path. Uses
    /// the path's parametric `interpolatedLocation` to get smooth coverage
    /// regardless of input spacing.
    private static func sample(_ stroke: PKStroke, count: Int) -> [CGPoint] {
        let path = stroke.path
        guard path.count > 0 else { return [] }
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        // PKStrokePath is parameterised over its control-point indices.
        // interpolatedLocation(at:) returns the location at a fractional index.
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

    // MARK: - Line

    private static func scoreLine(points: [CGPoint], pathLength: CGFloat) -> (RecognizedShape, CGFloat)? {
        guard let first = points.first, let last = points.last else { return nil }
        // Residual = average perpendicular distance from each point to the
        // line through the endpoints.
        let dx = last.x - first.x
        let dy = last.y - first.y
        let len = hypot(dx, dy)
        guard len > 1 else { return nil }
        var sum: CGFloat = 0
        for p in points {
            // Cross product / len gives perpendicular distance.
            let num = abs((p.x - first.x) * dy - (p.y - first.y) * dx)
            sum += num / len
        }
        let residual = sum / CGFloat(points.count)
        // Confidence: low residual relative to the line's length means
        // the points cluster tightly around the straight line.
        let confidence = (1 - residual / max(20, len * 0.15)).clampedShape()
        return (.line(start: first, end: last), confidence)
    }

    // MARK: - Ellipse

    private static func scoreEllipse(points: [CGPoint], bbox: CGRect, pathLength: CGFloat) -> (RecognizedShape, CGFloat)? {
        // Residual = how far each point is from the ellipse inscribed in bbox.
        let cx = bbox.midX
        let cy = bbox.midY
        let rx = bbox.width  / 2
        let ry = bbox.height / 2
        guard rx > 2, ry > 2 else { return nil }
        var sum: CGFloat = 0
        for p in points {
            // Convert to normalised ellipse space; distance from unit circle.
            let nx = (p.x - cx) / rx
            let ny = (p.y - cy) / ry
            sum += abs(hypot(nx, ny) - 1)
        }
        let residual = sum / CGFloat(points.count)
        // Tighter tolerance — ellipses fit cleanly when drawn well.
        let confidence = (1 - residual / 0.25).clampedShape()
        return (.ellipse(rect: bbox), confidence)
    }

    // MARK: - Polygons (triangle, rectangle)

    /// Find `sides` corners by simplifying the polyline (Ramer-Douglas-Peucker
    /// flavour: pick the points with highest perpendicular distance from
    /// chord). Score the polygon formed by those corners against the original.
    private static func scorePolygon(points: [CGPoint], sides: Int, pathLength: CGFloat) -> (RecognizedShape, CGFloat)? {
        guard sides >= 3, points.count > sides else { return nil }
        let corners = findCorners(points, count: sides)
        guard corners.count == sides else { return nil }

        // Build the closed polygon edge-by-edge and average each input
        // point's distance to the nearest edge.
        var sum: CGFloat = 0
        for p in points {
            var minDist = CGFloat.greatestFiniteMagnitude
            for i in 0..<corners.count {
                let a = corners[i]
                let b = corners[(i + 1) % corners.count]
                minDist = Swift.min(minDist, distancePointToSegment(p, a, b))
            }
            sum += minDist
        }
        let residual = sum / CGFloat(points.count)
        let confidence = (1 - residual / 12).clampedShape()

        switch sides {
        case 3:
            // For triangles, return the three corners directly.
            return (.triangle(a: corners[0], b: corners[1], c: corners[2]), confidence)
        case 4:
            // For rectangles, normalise to an axis-aligned bbox of the corners.
            // (Free-rotated rectangles are a stretch goal — for now snap to bbox.)
            let bbox = boundingBox(corners)
            return (.rectangle(rect: bbox), confidence)
        default:
            return nil
        }
    }

    /// Pick `count` "corner" points from `points` — those with the highest
    /// perpendicular distance from the chord between their neighbours.
    /// Always includes the first point so a closed polygon's first vertex
    /// is well-defined.
    private static func findCorners(_ points: [CGPoint], count: Int) -> [CGPoint] {
        var candidates: [(idx: Int, score: CGFloat)] = []
        let stride = max(1, points.count / 32)
        for i in stride..<(points.count - stride) {
            let prev = points[i - stride]
            let next = points[i + stride]
            let chordLen = distance(prev, next)
            guard chordLen > 0.01 else { continue }
            let dx = next.x - prev.x
            let dy = next.y - prev.y
            let p = points[i]
            let perp = abs((p.x - prev.x) * dy - (p.y - prev.y) * dx) / chordLen
            candidates.append((i, perp))
        }
        // Pick top-`count` non-adjacent candidates, sorted by stroke order.
        candidates.sort { $0.score > $1.score }
        var picked: [Int] = []
        let minSpacing = max(2, points.count / (count + 1))
        for c in candidates {
            if picked.allSatisfy({ abs($0 - c.idx) >= minSpacing }) {
                picked.append(c.idx)
                if picked.count == count { break }
            }
        }
        picked.sort()
        return picked.map { points[$0] }
    }

    private static func distancePointToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        guard len2 > 0.0001 else { return distance(p, a) }
        // Projection parameter t in [0, 1] for points on the segment.
        var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2
        t = Swift.max(0, Swift.min(1, t))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        return hypot(p.x - projX, p.y - projY)
    }
}

// MARK: - Local clamp helper

private extension CGFloat {
    func clampedShape() -> CGFloat { Swift.max(0, Swift.min(1, self)) }
}

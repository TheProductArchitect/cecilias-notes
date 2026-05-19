import CoreGraphics
import Foundation
import UIKit

/// Geometry helpers for the lasso subsystem (Step 9).
/// All coordinates here are in the page's *point* coordinate
/// space (NOT normalised) — the lasso overlay captures gestures in
/// page-pt and converts at the model boundary.
enum LassoMath {

    /// Lasso mode — the user picks one of two freehand selection
    /// gestures. Persisted via UserDefaults (key `lasso.mode`).
    enum Mode: String, CaseIterable, Codable {
        case freeform     // hand-drawn closed shape
        case marquee      // axis-aligned rectangle from drag start → end
    }

    /// Build a closed `CGPath` from the user's drag points.
    /// Freeform: walks the sampled points and closes the path.
    /// Marquee: returns a rect from the first to the last point.
    static func selectionPath(
        for mode: Mode,
        points: [CGPoint]
    ) -> CGPath? {
        guard !points.isEmpty else { return nil }
        switch mode {
        case .freeform:
            guard points.count >= 3 else { return nil }
            let path = CGMutablePath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()
            return path
        case .marquee:
            guard let first = points.first, let last = points.last else { return nil }
            let rect = CGRect(
                x: min(first.x, last.x),
                y: min(first.y, last.y),
                width:  abs(last.x - first.x),
                height: abs(last.y - first.y)
            )
            return CGPath(rect: rect, transform: nil)
        }
    }

    /// Axis-aligned bounding box of a set of points. Used as a
    /// cheap pre-filter before per-point intersection tests.
    static func boundingBox(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x
        var minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Bounding box of a closed `CGPath`. `CGPath.boundingBoxOfPath`
    /// is the tight bound (controls excluded) — what we want for
    /// intersection tests.
    static func boundingBox(of path: CGPath) -> CGRect {
        path.boundingBoxOfPath
    }

    // MARK: - Containment

    /// True when `point` is inside the closed path. Uses the
    /// even-odd fill rule, which matches the visual closure of a
    /// freeform lasso (self-intersecting loops behave intuitively).
    static func contains(_ path: CGPath, _ point: CGPoint) -> Bool {
        path.contains(point, using: .evenOdd, transform: .identity)
    }

    /// True when an axis-aligned rectangle's centre is inside the
    /// lasso path. The architecture spec calls out centre-based
    /// inclusion as "more forgiving than full-overlap and feels
    /// right" for non-stroke elements.
    static func rectCentreContained(_ rect: CGRect, in path: CGPath) -> Bool {
        contains(path, CGPoint(x: rect.midX, y: rect.midY))
    }

    // MARK: - Affine transform builders

    /// Translation transform built around the origin. Simple
    /// wrapper kept here for symmetry with the other builders.
    static func translation(dx: CGFloat, dy: CGFloat) -> CGAffineTransform {
        CGAffineTransform(translationX: dx, y: dy)
    }

    /// Scale transform anchored at `anchor` — `T(anchor) · S(sx, sy) · T(-anchor)`.
    /// Used by both group-resize on non-stroke element positions and
    /// by per-stroke `PKStroke.transformed(using:)` calls.
    static func scale(sx: CGFloat, sy: CGFloat, around anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .scaledBy(x: sx, y: sy)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }

    /// Rotation transform anchored at `anchor` — `T(anchor) · R(θ) · T(-anchor)`.
    /// `angle` is in radians.
    static func rotation(angle: CGFloat, around anchor: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .rotated(by: angle)
            .translatedBy(x: -anchor.x, y: -anchor.y)
    }

    /// Apply a 2D affine to a single point.
    static func apply(_ transform: CGAffineTransform, to point: CGPoint) -> CGPoint {
        point.applying(transform)
    }
}

import SwiftUI

/// Pure path generators for each `ShapeKind`. Caller passes a
/// rectangle to fit the shape into; the function returns a `Path`
/// drawn inside that rect. No fills/strokes applied here — those
/// are the responsibility of the renderer.
///
/// Kept as a free function set rather than a method on ShapeKind so
/// the model layer (Core/Models/V6/ShapeContent.swift) doesn't pick
/// up a SwiftUI dependency.
enum ShapeKindPath {

    static func path(for kind: ShapeKind, in rect: CGRect) -> Path {
        switch kind {
        case .rectangle:
            return Path(rect)

        case .roundedRectangle:
            return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) * 0.12)

        case .ellipse:
            return Path(ellipseIn: rect)

        case .triangle:
            return Path { p in
                p.move(to:    CGPoint(x: rect.midX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                p.closeSubpath()
            }

        case .line:
            return Path { p in
                p.move(to:    CGPoint(x: rect.minX, y: rect.maxY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            }

        case .arrow:
            return arrowPath(in: rect)

        case .star:
            return starPath(in: rect, points: 5)

        case .heart:
            return heartPath(in: rect)

        case .callout:
            return calloutPath(in: rect)
        }
    }

    private static func arrowPath(in rect: CGRect) -> Path {
        // Body: horizontal line; head: short triangle on the right.
        let mid    = rect.midY
        let headW  = min(rect.width * 0.25, rect.height * 0.6)
        let headH  = rect.height * 0.35
        return Path { p in
            // Shaft
            p.move(to:    CGPoint(x: rect.minX, y: mid))
            p.addLine(to: CGPoint(x: rect.maxX - headW, y: mid))
            // Arrowhead — open V
            p.addLine(to: CGPoint(x: rect.maxX - headW, y: mid - headH))
            p.addLine(to: CGPoint(x: rect.maxX, y: mid))
            p.addLine(to: CGPoint(x: rect.maxX - headW, y: mid + headH))
            p.addLine(to: CGPoint(x: rect.maxX - headW, y: mid))
        }
    }

    private static func starPath(in rect: CGRect, points: Int) -> Path {
        let centre  = CGPoint(x: rect.midX, y: rect.midY)
        let outerR  = min(rect.width, rect.height) / 2
        let innerR  = outerR * 0.45
        let step    = .pi / Double(points)
        return Path { p in
            for i in 0..<(points * 2) {
                let r = i.isMultiple(of: 2) ? outerR : innerR
                let angle = -.pi / 2 + step * Double(i)
                let pt = CGPoint(
                    x: centre.x + r * cos(angle),
                    y: centre.y + r * sin(angle)
                )
                if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
            }
            p.closeSubpath()
        }
    }

    private static func heartPath(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        return Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.addCurve(
                to:       CGPoint(x: rect.minX, y: rect.minY + h * 0.30),
                control1: CGPoint(x: rect.minX,            y: rect.maxY - h * 0.30),
                control2: CGPoint(x: rect.minX,            y: rect.minY + h * 0.50)
            )
            p.addArc(
                center: CGPoint(x: rect.minX + w * 0.25, y: rect.minY + h * 0.30),
                radius: w * 0.25,
                startAngle: .degrees(180),
                endAngle:   .degrees(0),
                clockwise:  false
            )
            p.addArc(
                center: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 0.30),
                radius: w * 0.25,
                startAngle: .degrees(180),
                endAngle:   .degrees(0),
                clockwise:  false
            )
            p.addCurve(
                to:       CGPoint(x: rect.midX, y: rect.maxY),
                control1: CGPoint(x: rect.maxX, y: rect.minY + h * 0.50),
                control2: CGPoint(x: rect.maxX, y: rect.maxY - h * 0.30)
            )
            p.closeSubpath()
        }
    }

    private static func calloutPath(in rect: CGRect) -> Path {
        // Rounded body with a small triangular tail on the bottom-left.
        let bodyHeight = rect.height * 0.85
        let body = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: bodyHeight
        )
        let radius = min(body.width, body.height) * 0.12
        return Path { p in
            p.addRoundedRect(in: body, cornerSize: CGSize(width: radius, height: radius))
            // Tail
            let tailLeft   = CGPoint(x: rect.minX + rect.width * 0.18, y: body.maxY)
            let tailRight  = CGPoint(x: rect.minX + rect.width * 0.32, y: body.maxY)
            let tailPoint  = CGPoint(x: rect.minX + rect.width * 0.10, y: rect.maxY)
            p.move(to:    tailLeft)
            p.addLine(to: tailPoint)
            p.addLine(to: tailRight)
            p.closeSubpath()
        }
    }
}

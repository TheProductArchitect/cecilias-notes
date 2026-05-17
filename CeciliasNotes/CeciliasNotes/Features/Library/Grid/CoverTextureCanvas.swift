import SwiftUI

/// Renders CoverTexture programmatically via SwiftUI Canvas.
/// White strokes at 8% opacity — no image assets.
struct CoverTextureCanvas: View {
    let texture: CoverTexture

    var body: some View {
        Canvas { ctx, size in
            switch texture {
            case .none:  break
            case .linen: drawDiagonalLines(ctx, size, spacing: 8,  angle:  .pi / 4)
            case .ruled: drawHLines(ctx, size, spacing: 28)
            case .grid:
                drawHLines(ctx, size, spacing: 24)
                drawVLines(ctx, size, spacing: 24)
            case .dot:   drawDots(ctx, size, spacing: 20, radius: 1.5)
            case .craft:
                drawDiagonalLines(ctx, size, spacing: 12, angle:  .pi / 4)
                drawDiagonalLines(ctx, size, spacing: 12, angle: -.pi / 4)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Drawing primitives

    private let strokeColor = GraphicsContext.Shading.color(.white.opacity(0.08))
    private let lineWidth: CGFloat = 0.5

    private func drawHLines(_ ctx: GraphicsContext, _ size: CGSize, spacing: CGFloat) {
        var y: CGFloat = spacing
        while y < size.height {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: strokeColor, lineWidth: lineWidth)
            y += spacing
        }
    }

    private func drawVLines(_ ctx: GraphicsContext, _ size: CGSize, spacing: CGFloat) {
        var x: CGFloat = spacing
        while x < size.width {
            var p = Path()
            p.move(to: CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: strokeColor, lineWidth: lineWidth)
            x += spacing
        }
    }

    private func drawDiagonalLines(
        _ ctx: GraphicsContext, _ size: CGSize, spacing: CGFloat, angle: CGFloat
    ) {
        // Project lines perpendicular to `angle` across the bounding diagonal.
        let diagonal = (size.width + size.height)
        let steps    = Int(diagonal / spacing) + 2
        let dx = cos(angle + .pi / 2) * spacing
        let dy = sin(angle + .pi / 2) * spacing

        for i in -steps...steps {
            let offset = CGFloat(i) * spacing
            let cx = size.width  / 2 + cos(angle + .pi / 2) * offset
            let cy = size.height / 2 + sin(angle + .pi / 2) * offset
            let len = diagonal
            let sx  = cx - cos(angle) * len
            let sy  = cy - sin(angle) * len
            let ex  = cx + cos(angle) * len
            let ey  = cy + sin(angle) * len
            _ = (dx, dy)  // suppress unused warnings
            var p = Path()
            p.move(to: CGPoint(x: sx, y: sy))
            p.addLine(to: CGPoint(x: ex, y: ey))
            ctx.stroke(p, with: strokeColor, lineWidth: lineWidth)
        }
    }

    private func drawDots(
        _ ctx: GraphicsContext, _ size: CGSize, spacing: CGFloat, radius: CGFloat
    ) {
        var y: CGFloat = spacing
        while y < size.height {
            var x: CGFloat = spacing
            while x < size.width {
                let rect = CGRect(x: x - radius, y: y - radius,
                                  width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: rect), with: strokeColor)
                x += spacing
            }
            y += spacing
        }
    }
}

// MARK: - Mini preview for the texture picker

struct CoverTexturePreview: View {
    let texture: CoverTexture
    let isSelected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .fill(Color.inkAccentPrimary.opacity(0.7))
            CoverTextureCanvas(texture: texture)
                .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))
        }
        .frame(width: 52, height: 52)
        .overlay(
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.inkAccentPrimary : Color.inkBorderDefault,
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
    }
}

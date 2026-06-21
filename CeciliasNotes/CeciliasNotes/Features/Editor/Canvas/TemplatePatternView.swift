import SwiftUI

/// SwiftUI Canvas-backed renderer for every page template. Single
/// source of truth — the same view paints both the editor canvas
/// background (full-page, mounted behind PKCanvasView via a hosting
/// controller) and the customise panel's thumbnails. The rendering
/// differs only by `isThumbnail`, which compresses the spacing and
/// trims the inset margins so the pattern is legible at thumbnail
/// scale.
///
/// Lines stay at a fixed grey regardless of system theme. The page
/// background paper colour is owned by `PageRenderer` (full page) or
/// the thumbnail container (panel), so dark mode adapts there — the
/// pattern itself is theme-agnostic so the visual relationship between
/// paper and ruling stays consistent.
struct TemplatePatternView: View {
    let template: PageTemplate
    var isThumbnail: Bool = false

    private var lineColor: Color {
        // Slightly darker on the small thumbnail so the pattern still
        // reads at 80×104pt; lighter on the full page so it never
        // competes with strokes.
        isThumbnail
            ? Color(red: 0.61, green: 0.61, blue: 0.59)   // #9C9C98
            : Color(red: 0.85, green: 0.85, blue: 0.83)   // #D9D9D4
    }

    var body: some View {
        Canvas { ctx, size in
            switch template {
            case .blank:           break
            case .narrowRuled:     drawHorizontalLines(ctx, size: size, spacingMM: 7)
            case .wideRuled:       drawHorizontalLines(ctx, size: size, spacingMM: 10)
            case .collegeRuled:    drawCollegeRuled(ctx, size: size)
            case .twoColumn:       drawTwoColumn(ctx, size: size)
            case .dotGrid5:        drawDotGrid(ctx, size: size, spacingMM: 5)
            case .dotGrid10:       drawDotGrid(ctx, size: size, spacingMM: 10)
            case .isoDots:         drawIsoDots(ctx, size: size)
            case .squareGrid5:     drawSquareGrid(ctx, size: size, spacingMM: 5)
            case .squareGrid10:    drawSquareGrid(ctx, size: size, spacingMM: 10)
            case .engineeringGrid: drawEngineeringGrid(ctx, size: size)
            case .cornell:         drawCornell(ctx, size: size)
            case .music:           drawMusic(ctx, size: size)
            case .storyboard:      drawStoryboard(ctx, size: size)
            case .mindMap:         drawMindMap(ctx, size: size)
            case .calendarWeek:    drawCalendarWeek(ctx, size: size)
            case .dayPlanner:      drawDayPlanner(ctx, size: size)
            case .taskList:        drawTaskList(ctx, size: size)
            case .habitTracker:    drawHabitTracker(ctx, size: size)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: - Geometry helpers

    /// Convert millimetres into points for the surface we're drawing
    /// on. Full-page uses ~2.83 pt/mm (96dpi); thumbnails compress
    /// proportionally so a 5mm grid still shows two grid cells in an
    /// 80pt-wide preview.
    private func mm(_ value: CGFloat) -> CGFloat {
        isThumbnail ? value * 0.6 : value * 2.83
    }

    private var hInset: CGFloat { isThumbnail ? 4 : 16 }

    // MARK: - Lined

    private func drawHorizontalLines(_ ctx: GraphicsContext, size: CGSize, spacingMM: CGFloat) {
        let nominal = mm(spacingMM)
        // Distribute the remainder evenly so the top "gap" before the
        // first rule and the bottom "gap" after the last rule are
        // equal — earlier the loop started at y=spacing and stopped
        // before the bottom edge, leaving one full spacing gap at
        // the top and a partial gap at the bottom. Now the gap on
        // each side is half the size.height % spacing remainder, so
        // the rules read centred on the page.
        let lines = max(1, Int(size.height / nominal))
        let usedHeight = CGFloat(lines) * nominal
        let topOffset = max(0, (size.height - usedHeight) / 2)
        var y = topOffset + nominal
        while y < size.height {
            var p = Path()
            p.move(to:    CGPoint(x: hInset,                  y: y))
            p.addLine(to: CGPoint(x: size.width - hInset,     y: y))
            ctx.stroke(p, with: .color(lineColor), lineWidth: 0.5)
            y += nominal
        }
    }

    private func drawCollegeRuled(_ ctx: GraphicsContext, size: CGSize) {
        drawHorizontalLines(ctx, size: size, spacingMM: 9)
        // Red margin line on the left.
        let marginX = size.width * 0.12
        var p = Path()
        p.move(to:    CGPoint(x: marginX, y: 0))
        p.addLine(to: CGPoint(x: marginX, y: size.height))
        ctx.stroke(p, with: .color(Color(red: 0.88, green: 0.55, blue: 0.55)), lineWidth: 0.5)
    }

    private func drawTwoColumn(_ ctx: GraphicsContext, size: CGSize) {
        let centerX = size.width / 2
        var divider = Path()
        divider.move(to:    CGPoint(x: centerX, y: 0))
        divider.addLine(to: CGPoint(x: centerX, y: size.height))
        ctx.stroke(divider, with: .color(lineColor), lineWidth: 0.5)

        let spacing = mm(9)
        let inset: CGFloat = isThumbnail ? 2 : 12
        var y = spacing
        while y < size.height {
            var lp = Path()
            lp.move(to:    CGPoint(x: inset,        y: y))
            lp.addLine(to: CGPoint(x: centerX - 4,  y: y))
            ctx.stroke(lp, with: .color(lineColor), lineWidth: 0.4)

            var rp = Path()
            rp.move(to:    CGPoint(x: centerX + 4,           y: y))
            rp.addLine(to: CGPoint(x: size.width - inset,    y: y))
            ctx.stroke(rp, with: .color(lineColor), lineWidth: 0.4)
            y += spacing
        }
    }

    // MARK: - Dotted

    private func drawDotGrid(_ ctx: GraphicsContext, size: CGSize, spacingMM: CGFloat) {
        let nominal = mm(spacingMM)
        let dotSize: CGFloat = isThumbnail ? 0.7 : 1.5
        // Centred-grid offsets so the dot field reads balanced top↔︎
        // bottom and left↔︎right instead of one whole spacing gap at
        // the top + an irregular gap at the bottom.
        let cellsY = max(1, Int(size.height / nominal))
        let cellsX = max(1, Int(size.width  / nominal))
        let topOffset  = max(0, (size.height - CGFloat(cellsY) * nominal) / 2)
        let leftOffset = max(0, (size.width  - CGFloat(cellsX) * nominal) / 2)
        var y = topOffset + nominal
        while y < size.height {
            var x = leftOffset + nominal
            while x < size.width {
                let r = CGRect(
                    x: x - dotSize / 2,
                    y: y - dotSize / 2,
                    width: dotSize, height: dotSize
                )
                ctx.fill(Path(ellipseIn: r), with: .color(lineColor))
                x += nominal
            }
            y += nominal
        }
    }

    private func drawIsoDots(_ ctx: GraphicsContext, size: CGSize) {
        let spacing  = mm(7)
        let rowHeight = spacing * 0.866   // sin(60°)
        let dotSize: CGFloat = isThumbnail ? 0.7 : 1.5
        var y: CGFloat = rowHeight
        var rowIndex = 0
        while y < size.height {
            let xOffset = rowIndex.isMultiple(of: 2) ? 0 : spacing / 2
            var x = spacing / 2 + xOffset
            while x < size.width {
                let r = CGRect(
                    x: x - dotSize / 2,
                    y: y - dotSize / 2,
                    width: dotSize, height: dotSize
                )
                ctx.fill(Path(ellipseIn: r), with: .color(lineColor))
                x += spacing
            }
            y += rowHeight
            rowIndex += 1
        }
    }

    // MARK: - Grid

    private func drawSquareGrid(_ ctx: GraphicsContext, size: CGSize, spacingMM: CGFloat) {
        drawSquareGrid(ctx, size: size, spacing: mm(spacingMM), color: lineColor, lineWidth: 0.3)
    }

    private func drawSquareGrid(
        _ ctx: GraphicsContext, size: CGSize, spacing: CGFloat, color: Color, lineWidth: CGFloat
    ) {
        // Edge-to-edge grid: round the cell count to the nearest
        // whole number that fits, then scale the spacing so the
        // first and last lines sit exactly on the page edges and
        // the cells stay uniform. Earlier the loop started at
        // y=spacing and stopped before the bottom edge, leaving a
        // whole spacing gap at the top and an irregular gap at the
        // bottom — visible in the screenshot as the cream strip
        // above the grid.
        let cellsY = max(1, Int((size.height / spacing).rounded()))
        let cellsX = max(1, Int((size.width  / spacing).rounded()))
        let stepY = size.height / CGFloat(cellsY)
        let stepX = size.width  / CGFloat(cellsX)
        for i in 0...cellsY {
            let y = CGFloat(i) * stepY
            var p = Path()
            p.move(to:    CGPoint(x: 0,          y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(color), lineWidth: lineWidth)
        }
        for i in 0...cellsX {
            let x = CGFloat(i) * stepX
            var p = Path()
            p.move(to:    CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(color), lineWidth: lineWidth)
        }
    }

    private func drawEngineeringGrid(_ ctx: GraphicsContext, size: CGSize) {
        // Sub-grid (lighter, fine).
        drawSquareGrid(
            ctx, size: size,
            spacing: mm(1), color: lineColor.opacity(0.4), lineWidth: 0.2
        )
        // Main grid (darker, every 5mm).
        drawSquareGrid(
            ctx, size: size,
            spacing: mm(5), color: lineColor, lineWidth: 0.3
        )
    }

    // MARK: - Specialised

    private func drawCornell(_ ctx: GraphicsContext, size: CGSize) {
        let topBand    = size.height * 0.08
        let leftCol    = size.width  * 0.25
        let bottomBand = size.height * 0.18

        var top = Path()
        top.move(to:    CGPoint(x: 0,          y: topBand))
        top.addLine(to: CGPoint(x: size.width, y: topBand))
        ctx.stroke(top, with: .color(lineColor), lineWidth: 0.5)

        var left = Path()
        left.move(to:    CGPoint(x: leftCol, y: topBand))
        left.addLine(to: CGPoint(x: leftCol, y: size.height - bottomBand))
        ctx.stroke(left, with: .color(lineColor), lineWidth: 0.5)

        var bot = Path()
        bot.move(to:    CGPoint(x: 0,          y: size.height - bottomBand))
        bot.addLine(to: CGPoint(x: size.width, y: size.height - bottomBand))
        ctx.stroke(bot, with: .color(lineColor), lineWidth: 0.5)

        let spacing = mm(9)
        var y = topBand + spacing
        while y < size.height - bottomBand {
            var p = Path()
            p.move(to:    CGPoint(x: leftCol,    y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(lineColor.opacity(0.5)), lineWidth: 0.3)
            y += spacing
        }
    }

    private func drawMusic(_ ctx: GraphicsContext, size: CGSize) {
        let staffHeight: CGFloat  = isThumbnail ? 8  : 24
        let lineGap = staffHeight / 4
        let staffSpacing: CGFloat = isThumbnail ? 16 : 48

        var y: CGFloat = staffSpacing
        while y + staffHeight < size.height {
            for i in 0..<5 {
                let lineY = y + CGFloat(i) * lineGap
                var p = Path()
                p.move(to:    CGPoint(x: hInset,              y: lineY))
                p.addLine(to: CGPoint(x: size.width - hInset, y: lineY))
                ctx.stroke(p, with: .color(lineColor), lineWidth: 0.4)
            }
            y += staffSpacing
        }
    }

    private func drawStoryboard(_ ctx: GraphicsContext, size: CGSize) {
        let cols = 2
        let rows = 3
        let padding: CGFloat = isThumbnail ? 3  : 12
        let labelHeight: CGFloat = isThumbnail ? 4 : 16

        let cellWidth  = (size.width  - padding * CGFloat(cols + 1)) / CGFloat(cols)
        let cellHeight =
            (size.height - padding * CGFloat(rows + 1) - labelHeight * CGFloat(rows))
                / CGFloat(rows)

        for row in 0..<rows {
            for col in 0..<cols {
                let x = padding + CGFloat(col) * (cellWidth + padding)
                let y = padding + CGFloat(row) * (cellHeight + labelHeight + padding)
                let r = CGRect(x: x, y: y, width: cellWidth, height: cellHeight)
                ctx.stroke(Path(roundedRect: r, cornerRadius: 1),
                           with: .color(lineColor), lineWidth: 0.5)
            }
        }
    }

    private func drawMindMap(_ ctx: GraphicsContext, size: CGSize) {
        let centerX = size.width  / 2
        let centerY = size.height / 2
        let radius:  CGFloat = isThumbnail ? 12 : 40

        let rect = CGRect(
            x: centerX - radius, y: centerY - radius,
            width: radius * 2,   height: radius * 2
        )
        ctx.stroke(Path(ellipseIn: rect), with: .color(lineColor.opacity(0.6)), lineWidth: 0.5)

        let radial = max(size.width, size.height)
        for i in 0..<6 {
            let angle = Double(i) * .pi / 3
            let endX = centerX + cos(angle) * radial
            let endY = centerY + sin(angle) * radial
            var p = Path()
            p.move(to: CGPoint(
                x: centerX + cos(angle) * radius,
                y: centerY + sin(angle) * radius
            ))
            p.addLine(to: CGPoint(x: endX, y: endY))
            ctx.stroke(p, with: .color(lineColor.opacity(0.3)), lineWidth: 0.3)
        }
    }

    // MARK: - Planning

    private func drawCalendarWeek(_ ctx: GraphicsContext, size: CGSize) {
        let headerH:    CGFloat = isThumbnail ? 6 : 24
        let timeColW:   CGFloat = isThumbnail ? 6 : 28
        let cols = 7
        let rows = 14

        let colWidth  = (size.width  - timeColW) / CGFloat(cols)
        let rowHeight = (size.height - headerH)  / CGFloat(rows)

        var hp = Path()
        hp.move(to:    CGPoint(x: 0,          y: headerH))
        hp.addLine(to: CGPoint(x: size.width, y: headerH))
        ctx.stroke(hp, with: .color(lineColor), lineWidth: 0.5)

        for i in 0...cols {
            let x = timeColW + CGFloat(i) * colWidth
            var p = Path()
            p.move(to:    CGPoint(x: x, y: 0))
            p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: .color(lineColor.opacity(0.4)), lineWidth: 0.3)
        }
        for i in 1..<rows {
            let y = headerH + CGFloat(i) * rowHeight
            var p = Path()
            p.move(to:    CGPoint(x: timeColW,   y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(lineColor.opacity(0.3)), lineWidth: 0.2)
        }
    }

    private func drawDayPlanner(_ ctx: GraphicsContext, size: CGSize) {
        let timeColW = size.width * 0.18
        let rows = 16
        let rowHeight = size.height / CGFloat(rows)

        var divider = Path()
        divider.move(to:    CGPoint(x: timeColW, y: 0))
        divider.addLine(to: CGPoint(x: timeColW, y: size.height))
        ctx.stroke(divider, with: .color(lineColor), lineWidth: 0.5)

        for i in 1..<rows {
            let y = CGFloat(i) * rowHeight
            var p = Path()
            p.move(to:    CGPoint(x: 0,          y: y))
            p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: .color(lineColor.opacity(0.4)), lineWidth: 0.3)
        }
    }

    private func drawTaskList(_ ctx: GraphicsContext, size: CGSize) {
        let rowHeight = mm(10)
        let checkSize: CGFloat = isThumbnail ? 3 : 12
        let leftPad:   CGFloat = isThumbnail ? 4 : 20

        var y = rowHeight
        while y < size.height {
            let box = CGRect(
                x: leftPad,
                y: y - checkSize / 2,
                width: checkSize, height: checkSize
            )
            ctx.stroke(Path(roundedRect: box, cornerRadius: 1),
                       with: .color(lineColor), lineWidth: 0.4)

            var line = Path()
            line.move(to:    CGPoint(x: leftPad + checkSize + 4,  y: y + checkSize / 2))
            line.addLine(to: CGPoint(x: size.width - leftPad,     y: y + checkSize / 2))
            ctx.stroke(line, with: .color(lineColor.opacity(0.5)), lineWidth: 0.3)

            y += rowHeight
        }
    }

    private func drawHabitTracker(_ ctx: GraphicsContext, size: CGSize) {
        let leftColW = size.width * 0.3
        let cellSize = (size.width - leftColW) / 30
        let rows = max(8, Int(size.height / cellSize))

        var divider = Path()
        divider.move(to:    CGPoint(x: leftColW, y: 0))
        divider.addLine(to: CGPoint(x: leftColW, y: size.height))
        ctx.stroke(divider, with: .color(lineColor), lineWidth: 0.4)

        for row in 0..<rows {
            let y = CGFloat(row) * cellSize
            var rp = Path()
            rp.move(to:    CGPoint(x: 0,          y: y))
            rp.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(rp, with: .color(lineColor.opacity(0.3)), lineWidth: 0.2)

            for col in 0...30 {
                let x = leftColW + CGFloat(col) * cellSize
                var p = Path()
                p.move(to:    CGPoint(x: x, y: y))
                p.addLine(to: CGPoint(x: x, y: y + cellSize))
                ctx.stroke(p, with: .color(lineColor.opacity(0.3)), lineWidth: 0.2)
            }
        }
    }
}

import UIKit

/// Draws the page paper colour, template, and casts the page-boundary shadow.
/// All drawing is done with Core Graphics — never with PencilKit.
///
/// PageRenderer sits *behind* PKCanvasView inside the scroll view's content view,
/// so they zoom together. Its frame and the canvas frame are kept in sync by
/// the canvas container coordinator.
final class PageRenderer: UIView {

    // MARK: Configuration
    private(set) var pageSize: PageSize
    private(set) var template: PageTemplate

    // MARK: Init

    init(pageSize: PageSize, template: PageTemplate) {
        self.pageSize  = pageSize
        self.template  = template
        super.init(frame: CGRect(origin: .zero, size: pageSize.pointSize))
        configureLayer()
        contentMode  = .redraw
        isOpaque     = true
        clearsContextBeforeDrawing = false
        backgroundColor = .clear   // we paint in draw(_:)
    }

    /// PageRenderer is constructed programmatically — never loaded from a storyboard.
    /// `@available(*, unavailable)` blocks misuse at compile time; the `nil` return
    /// keeps shipping code crash-free if something exotic still routes here.
    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // MARK: Public mutators

    func update(pageSize: PageSize, template: PageTemplate) {
        let needsBoundsUpdate = pageSize != self.pageSize
        self.pageSize  = pageSize
        self.template  = template
        if needsBoundsUpdate {
            frame = CGRect(origin: frame.origin, size: pageSize.pointSize)
        }
        setNeedsDisplay()
    }

    // MARK: Layer / shadow

    private func configureLayer() {
        // Page-boundary shadow — second of only two shadows in the entire app.
        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOffset  = CGSize(width: 0, height: 1)
        layer.shadowRadius  = 4
        layer.shadowOpacity = 0.08
        layer.masksToBounds = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Ensure shadow path tracks bounds — avoids per-frame off-screen rasterisation.
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previousTraitCollection) {
            setNeedsDisplay()
        }
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let bounds = self.bounds

        // 1. Paper colour
        let isDark = traitCollection.userInterfaceStyle == .dark
        let paper  = isDark ? UIColor(hex: "#1C1C1A") : UIColor(hex: "#FAFAF8")
        ctx.setFillColor(paper.cgColor)
        ctx.fill(bounds)

        // 2. Template
        switch template {
        case .blank:
            break
        case .lined(let spacing):
            drawLined(ctx: ctx, in: bounds, spacing: spacing)
        case .grid(let spacing):
            drawGrid(ctx: ctx, in: bounds, spacing: spacing)
        case .dotGrid(let spacing, let dotSize):
            drawDotGrid(ctx: ctx, in: bounds, spacing: spacing, dotSize: dotSize)
        case .cornell:
            drawCornell(ctx: ctx, in: bounds)
        case .music:
            drawMusic(ctx: ctx, in: bounds)
        }
    }

    // MARK: Template renderers

    private func drawLined(ctx: CGContext, in rect: CGRect, spacing: CGFloat) {
        let stroke = UIColor.inkTextTertiary.withAlphaComponent(0.25).cgColor
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(0.5)
        var y = spacing
        while y < rect.height {
            ctx.move(to:    CGPoint(x: 0,         y: y))
            ctx.addLine(to: CGPoint(x: rect.width, y: y))
            y += spacing
        }
        ctx.strokePath()
    }

    private func drawGrid(ctx: CGContext, in rect: CGRect, spacing: CGFloat) {
        let stroke = UIColor.inkTextTertiary.withAlphaComponent(0.20).cgColor
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(0.5)

        var y = spacing
        while y < rect.height {
            ctx.move(to:    CGPoint(x: 0,          y: y))
            ctx.addLine(to: CGPoint(x: rect.width,  y: y))
            y += spacing
        }
        var x = spacing
        while x < rect.width {
            ctx.move(to:    CGPoint(x: x, y: 0))
            ctx.addLine(to: CGPoint(x: x, y: rect.height))
            x += spacing
        }
        ctx.strokePath()
    }

    private func drawDotGrid(
        ctx: CGContext, in rect: CGRect, spacing: CGFloat, dotSize: CGFloat
    ) {
        let fill = UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor
        ctx.setFillColor(fill)

        let r = max(0.5, dotSize)
        var y = spacing
        while y < rect.height {
            var x = spacing
            while x < rect.width {
                let dotRect = CGRect(
                    x: x - r / 2, y: y - r / 2,
                    width: r,     height: r
                )
                ctx.fillEllipse(in: dotRect)
                x += spacing
            }
            y += spacing
        }
    }

    private func drawCornell(ctx: CGContext, in rect: CGRect) {
        let lineColour = UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor
        ctx.setStrokeColor(lineColour)
        ctx.setLineWidth(0.5)

        let marginX = rect.width  * 0.20    // vertical margin 20% from left
        let titleY  = rect.height * 0.15    // horizontal title line 15% from top

        // Vertical margin line
        ctx.move(to:    CGPoint(x: marginX, y: titleY))
        ctx.addLine(to: CGPoint(x: marginX, y: rect.height * 0.78))

        // Horizontal title line
        ctx.move(to:    CGPoint(x: 0,          y: titleY))
        ctx.addLine(to: CGPoint(x: rect.width,  y: titleY))

        // Summary line
        let summaryY = rect.height * 0.78
        ctx.move(to:    CGPoint(x: 0,         y: summaryY))
        ctx.addLine(to: CGPoint(x: rect.width, y: summaryY))
        ctx.strokePath()

        // Labels — drawn with NSAttributedString
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.inkCaption,
            .foregroundColor: UIColor.inkTextTertiary,
        ]
        let pad: CGFloat = 8
        ("Topic" as NSString).draw(
            at: CGPoint(x: pad, y: titleY - UIFont.inkCaption.lineHeight - 2),
            withAttributes: labelAttrs
        )
        ("Notes" as NSString).draw(
            at: CGPoint(x: marginX + pad, y: titleY + 2),
            withAttributes: labelAttrs
        )
        ("Summary" as NSString).draw(
            at: CGPoint(x: pad, y: summaryY + 2),
            withAttributes: labelAttrs
        )
    }

    private func drawMusic(ctx: CGContext, in rect: CGRect) {
        let stroke = UIColor.inkTextTertiary.withAlphaComponent(0.30).cgColor
        ctx.setStrokeColor(stroke)
        ctx.setLineWidth(0.5)

        let lineSpacing:  CGFloat = 8
        let staveSpacing: CGFloat = 24
        let staveHeight = lineSpacing * 4
        let staveTotal  = staveHeight + staveSpacing

        var y: CGFloat = staveSpacing
        while y + staveHeight < rect.height {
            for line in 0..<5 {
                let lineY = y + CGFloat(line) * lineSpacing
                ctx.move(to:    CGPoint(x: 16,              y: lineY))
                ctx.addLine(to: CGPoint(x: rect.width - 16, y: lineY))
            }
            y += staveTotal
        }
        ctx.strokePath()
    }
}

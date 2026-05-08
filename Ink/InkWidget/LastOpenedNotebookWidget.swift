import WidgetKit
import SwiftUI

// MARK: - LastOpenedNotebookWidget (small)

struct LastOpenedNotebookWidget: Widget {
    let kind = "LastOpenedNotebook"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            LastOpenedView(entry: entry)
                .containerBackground(for: .widget) { background(for: entry) }
        }
        .configurationDisplayName("Last Notebook")
        .description("Quick access to the notebook you opened most recently.")
        .supportedFamilies([.systemSmall])
    }

    @ViewBuilder
    private func background(for entry: NotebookEntry) -> some View {
        if let nb = entry.primary {
            ZStack {
                Color(hex: nb.coverColorHex)
                CoverTextureCanvas(texture: nb.coverTexture)
            }
        } else {
            Color(hex: "#1D1D1B")
        }
    }
}

// MARK: - Layout

struct LastOpenedView: View {
    let entry: NotebookEntry

    var body: some View {
        if let nb = entry.primary {
            content(for: nb)
                .widgetURL(deepLink(for: nb.id))
        } else {
            emptyState
        }
    }

    private func content(for nb: NotebookSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer()
            Text(nb.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(2)
            Text("\(nb.pageCount) page\(nb.pageCount == 1 ? "" : "s")")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            HStack {
                Spacer()
                Text("Ink")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "book.closed")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(.white.opacity(0.7))
            Text("No notebooks yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private func deepLink(for id: UUID) -> URL? {
        URL(string: "ink://open/\(id.uuidString)")
    }
}

// MARK: - CoverTextureCanvas (widget copy — no app dependency)

struct CoverTextureCanvas: View {
    let texture: String   // CoverTexture.rawValue

    var body: some View {
        Canvas { ctx, size in
            switch texture {
            case "linen":  drawLinen(ctx: ctx, size: size)
            case "grid":   drawGrid(ctx: ctx, size: size)
            case "dot":    drawDot(ctx: ctx, size: size)
            case "ruled":  drawRuled(ctx: ctx, size: size)
            case "craft":  drawCraft(ctx: ctx, size: size)
            default:       break
            }
        }
        .opacity(0.16)
    }

    private func drawLinen(ctx: GraphicsContext, size: CGSize) {
        let stroke = GraphicsContext.Shading.color(.white)
        var x: CGFloat = 0
        while x < size.width {
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: stroke, lineWidth: 0.5); x += 3
        }
    }

    private func drawGrid(ctx: GraphicsContext, size: CGSize) {
        let stroke = GraphicsContext.Shading.color(.white)
        let step: CGFloat = 12
        var x: CGFloat = 0
        while x < size.width {
            var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            ctx.stroke(p, with: stroke, lineWidth: 0.5); x += step
        }
        var y: CGFloat = 0
        while y < size.height {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: stroke, lineWidth: 0.5); y += step
        }
    }

    private func drawDot(ctx: GraphicsContext, size: CGSize) {
        let fill = GraphicsContext.Shading.color(.white)
        let step: CGFloat = 12
        var x: CGFloat = step
        while x < size.width {
            var y: CGFloat = step
            while y < size.height {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2)),
                         with: fill)
                y += step
            }
            x += step
        }
    }

    private func drawRuled(ctx: GraphicsContext, size: CGSize) {
        let stroke = GraphicsContext.Shading.color(.white)
        var y: CGFloat = 14
        while y < size.height {
            var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            ctx.stroke(p, with: stroke, lineWidth: 0.5); y += 14
        }
    }

    private func drawCraft(ctx: GraphicsContext, size: CGSize) {
        let stroke = GraphicsContext.Shading.color(.white)
        for _ in 0..<200 {
            let x = CGFloat.random(in: 0...size.width)
            let y = CGFloat.random(in: 0...size.height)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: stroke)
        }
    }
}

// MARK: - Color hex init for the widget target

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.hasPrefix("#") ? String(s.dropFirst()) : s
        var rgb: UInt64 = 0
        Scanner(string: s).scanHexInt64(&rgb)
        let r = Double((rgb & 0xFF0000) >> 16) / 255
        let g = Double((rgb & 0x00FF00) >> 8) / 255
        let b = Double(rgb & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b)
    }
}

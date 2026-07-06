import SwiftUI

/// Page background patterns (ruled, dot grid, etc.) shared by the doc
/// editor and the template picker sheet.
struct MacTemplateBackground: View {
    let template: PageTemplate
    let theme: Theme

    var body: some View {
        switch template {
        case .blank:
            theme.pageBackground
        case .narrowRuled, .wideRuled, .collegeRuled, .twoColumn:
            ruledBackground(spacing: 24)
        case .dotGrid5, .dotGrid10, .isoDots:
            dotBackground(spacing: 24)
        case .squareGrid5, .squareGrid10, .engineeringGrid:
            gridBackground(spacing: 24)
        default:
            theme.pageBackground
        }
    }

    private func ruledBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(theme.pageLines), lineWidth: 0.5)
                y += spacing
            }
        }
    }

    private func dotBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var x = spacing
                while x < size.width {
                    let dot = Path(ellipseIn: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                    context.fill(dot, with: .color(theme.pageDots))
                    x += spacing
                }
                y += spacing
            }
        }
    }

    private func gridBackground(spacing: CGFloat) -> some View {
        Canvas { context, size in
            var y = spacing
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(path, with: .color(theme.pageLines.opacity(0.8)), lineWidth: 0.5)
                y += spacing
            }
            var x = spacing
            while x < size.width {
                var path = Path()
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(theme.pageLines.opacity(0.8)), lineWidth: 0.5)
                x += spacing
            }
        }
    }
}

import SwiftUI

struct NewPagesSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                pageSizeCard
                templateCard
                autoAddCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("New Pages")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Page size

    private var pageSizeCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Default Page Size")

            Picker("Page size", selection: $viewModel.defaultPageSize) {
                ForEach(PageSize.allCases, id: \.rawValue) { size in
                    Text(size.displayName).tag(size)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Template picker

    private var templateCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Default Template")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Ink.Spacing.sm) {
                    ForEach(PageTemplate.defaults, id: \.self) { template in
                        TemplateMiniPreview(
                            template: template,
                            isSelected: viewModel.defaultTemplate == template
                        ) {
                            viewModel.defaultTemplate = template
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Auto-add

    private var autoAddCard: some View {
        Toggle(isOn: $viewModel.autoAddPage) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Auto-Add Page", systemImage: "plus.rectangle.on.rectangle")
                    .font(.inkBody)
                    .foregroundColor(.inkTextPrimary)
                Text("Automatically add a page when you reach the end.")
                    .font(.inkCaption)
                    .foregroundColor(.inkTextTertiary)
            }
        }
        .toggleStyle(.switch)
        .tint(.inkAccentPrimary)
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkSubhead)
            .foregroundColor(.inkTextSecondary)
    }
}

// MARK: - TemplateMiniPreview

private struct TemplateMiniPreview: View {
    let template:   PageTemplate
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: Ink.Spacing.xs) {
                ZStack {
                    RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                        .fill(Color.inkBackgroundElevated)
                        .frame(width: 60, height: 80)

                    Canvas { ctx, size in
                        drawTemplate(ctx: ctx, size: size)
                    }
                    .frame(width: 60, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.inkAccentPrimary : Color.inkBorderDefault,
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )

                Text(templateName)
                    .font(.inkCaption)
                    .foregroundColor(isSelected ? .inkAccentPrimary : .inkTextTertiary)
                    .lineLimit(1)
                    .frame(width: 60)
            }
        }
        .buttonStyle(.plain)
    }

    private var templateName: String {
        switch template {
        case .blank:         return "Blank"
        case .lined:         return "Lined"
        case .grid:          return "Grid"
        case .dotGrid:       return "Dot Grid"
        case .cornell:       return "Cornell"
        case .music:         return "Music"
        }
    }

    private func drawTemplate(ctx: GraphicsContext, size: CGSize) {
        let lineColor = Color.inkTextTertiary.opacity(0.5)
        switch template {
        case .blank:
            break

        case .lined(let spacing):
            let step = max(spacing * (size.height / 200), 6)
            var y = step
            while y < size.height {
                var path = Path()
                path.move(to: CGPoint(x: 4, y: y))
                path.addLine(to: CGPoint(x: size.width - 4, y: y))
                ctx.stroke(path, with: .color(lineColor), lineWidth: 0.5)
                y += step
            }

        case .grid(let spacing):
            let step = max(spacing * (size.height / 200), 6)
            var x: CGFloat = step
            while x < size.width {
                var p = Path(); p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
                ctx.stroke(p, with: .color(lineColor), lineWidth: 0.5); x += step
            }
            var y: CGFloat = step
            while y < size.height {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(p, with: .color(lineColor), lineWidth: 0.5); y += step
            }

        case .dotGrid(let spacing, _):
            let step = max(spacing * (size.height / 200), 6)
            var x: CGFloat = step
            while x < size.width {
                var y: CGFloat = step
                while y < size.height {
                    let rect = CGRect(x: x - 1, y: y - 1, width: 2, height: 2)
                    ctx.fill(Path(ellipseIn: rect), with: .color(lineColor))
                    y += step
                }
                x += step
            }

        case .cornell:
            // Margin line at 20%
            var p = Path()
            p.move(to: CGPoint(x: size.width * 0.2, y: 0))
            p.addLine(to: CGPoint(x: size.width * 0.2, y: size.height))
            ctx.stroke(p, with: .color(lineColor), lineWidth: 0.5)
            // Horizontal lines
            var y: CGFloat = 8
            while y < size.height {
                var lp = Path()
                lp.move(to: CGPoint(x: 0, y: y)); lp.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(lp, with: .color(lineColor), lineWidth: 0.5); y += 8
            }

        case .music:
            // 5-line staff groups
            let staffH: CGFloat = 12
            var groupY: CGFloat = 6
            while groupY + staffH < size.height {
                for i in 0..<5 {
                    let y = groupY + CGFloat(i) * (staffH / 4)
                    var lp = Path()
                    lp.move(to: CGPoint(x: 4, y: y)); lp.addLine(to: CGPoint(x: size.width - 4, y: y))
                    ctx.stroke(lp, with: .color(lineColor), lineWidth: 0.5)
                }
                groupY += staffH + 6
            }
        }
    }
}


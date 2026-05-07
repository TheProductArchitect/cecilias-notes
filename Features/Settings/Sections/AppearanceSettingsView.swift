import SwiftUI

// MARK: - AppearanceSettingsView

struct AppearanceSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Ink.Spacing.lg) {
                sectionHeader("Theme")

                ThemePickerView(themeManager: viewModel.themeManager)
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkSubhead)
            .foregroundColor(.inkTextSecondary)
    }
}

// MARK: - ThemePickerView

/// ForEach(InkTheme.allCases) — adding a theme case requires zero structural changes here.
struct ThemePickerView: View {
    @ObservedObject var themeManager: ThemeManager

    var body: some View {
        HStack(alignment: .top, spacing: Ink.Spacing.md) {
            ForEach(InkTheme.allCases, id: \.rawValue) { theme in
                ThemePreviewCard(
                    theme: theme,
                    isSelected: themeManager.theme == theme
                ) {
                    withAnimation(.inkSpring(InkSpring.snappy)) {
                        themeManager.theme = theme
                    }
                }
            }
            Spacer()
        }
    }
}

// MARK: - ThemePreviewCard

private struct ThemePreviewCard: View {
    let theme:      InkTheme
    let isSelected: Bool
    let onTap:      () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: Ink.Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    cardCanvas

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white, Color.inkAccentPrimary)
                            .padding(Ink.Spacing.sm)
                    }
                }
                .frame(width: 160, height: 200)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.md, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Ink.Radius.md, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.inkAccentPrimary : Color.inkBorderDefault,
                            lineWidth: isSelected ? 2 : 0.5
                        )
                )
                Text(theme.displayName)
                    .font(.inkFootnote)
                    .foregroundColor(isSelected ? .inkTextPrimary : .inkTextSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Card canvas

    private var cardCanvas: some View {
        ZStack {
            theme.previewBackground

            VStack(spacing: 0) {
                // Simulated notebook card
                notebookCard
                    .padding(Ink.Spacing.md)
                    .padding(.top, Ink.Spacing.sm)

                // Stroke curves
                strokeCanvas
                    .frame(height: 60)
                    .padding(.horizontal, Ink.Spacing.md)
                    .padding(.bottom, Ink.Spacing.sm)
            }
        }
    }

    // Simulated mini notebook card inside the preview
    private var notebookCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.xs) {
            // Title line
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.previewText)
                .frame(width: 80, height: 6)

            // Subtitle lines
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.previewText.opacity(0.45))
                .frame(width: 100, height: 4)

            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(theme.previewText.opacity(0.45))
                .frame(width: 72, height: 4)

            Spacer().frame(height: Ink.Spacing.xs)

            // Accent pill
            RoundedRectangle(cornerRadius: Ink.Radius.full, style: .continuous)
                .fill(theme.previewAccent)
                .frame(width: 40, height: 8)
        }
        .padding(Ink.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.previewBackground.opacity(0.7))
        .overlay(
            RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous)
                .strokeBorder(theme.previewText.opacity(0.12), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
    }

    // Three simulated bezier ink strokes
    private var strokeCanvas: some View {
        Canvas { ctx, size in
            let stroke = theme.previewStroke
            ctx.stroke(
                curvePath(in: size, yFraction: 0.25, amplitude: 0.5),
                with: .color(stroke),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            )
            ctx.stroke(
                curvePath(in: size, yFraction: 0.55, amplitude: -0.4),
                with: .color(stroke.opacity(0.7)),
                style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round)
            )
            ctx.stroke(
                curvePath(in: size, yFraction: 0.82, amplitude: 0.3),
                with: .color(stroke.opacity(0.45)),
                style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round)
            )
        }
    }

    private func curvePath(in size: CGSize, yFraction: CGFloat, amplitude: CGFloat) -> Path {
        let y    = size.height * yFraction
        let cpY  = y + size.height * amplitude * 0.35
        var path = Path()
        path.move(to: CGPoint(x: 0, y: y))
        path.addCurve(
            to: CGPoint(x: size.width, y: y + size.height * amplitude * 0.1),
            control1: CGPoint(x: size.width * 0.3, y: cpY),
            control2: CGPoint(x: size.width * 0.7, y: y - cpY * 0.5)
        )
        return path
    }
}

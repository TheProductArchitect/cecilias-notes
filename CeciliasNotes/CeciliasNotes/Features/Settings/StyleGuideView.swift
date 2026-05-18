import SwiftUI

#if DEBUG
struct StyleGuideView: View {
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @State private var sampleText = ""
    @State private var isButtonLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CeciliasNotes.Spacing.xl, pinnedViews: []) {
                    colorsSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    typographySection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    spacingSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    buttonsSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    textFieldSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    badgesSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    emptyStateSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    themeSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    animationSection
                    CeciliasNotesDivider().padding(.horizontal, CeciliasNotes.Spacing.md)
                    iconPreviewSection
                }
                .padding(.vertical, CeciliasNotes.Spacing.lg)
            }
            .background(theme.background)
            .navigationTitle("Style Guide")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    CeciliasNotesBadge("DEBUG", style: .accent)
                }
            }
        }
    }

    // MARK: Sections

    private var colorsSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("Colour Tokens")

            colorGroup("Background", swatches: [
                ("background.primary",   theme.background),
                ("background.secondary", theme.surface),
                ("background.tertiary",  theme.surfaceElevated),
                ("background.elevated",  theme.surfaceElevated),
            ])

            colorGroup("Text", swatches: [
                ("text.primary",   theme.foreground),
                ("text.secondary", theme.foregroundMuted),
                ("text.tertiary",  theme.foregroundSubtle),
            ])

            colorGroup("Accent", swatches: [
                ("accent.primary",   theme.accent),
                ("accent.secondary", theme.accentMuted),
            ])

            colorGroup("Border", swatches: [
                ("border.subtle",   theme.borderSubtle),
                ("border.default",  theme.borderDefault),
                ("border.emphasis", theme.borderEmphasis),
            ])

            colorGroup("Semantic", swatches: [
                ("destructive", theme.danger),
            ])
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var typographySection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            sectionHeader("Typography")

            Group {
                typeRow(".ceciliasNotesDisplay",  sample: "The quick brown fox",   font: .ceciliasNotesDisplay)
                typeRow(".ceciliasNotesTitle1",   sample: "The quick brown fox",   font: .ceciliasNotesTitle1)
                typeRow(".ceciliasNotesTitle2",   sample: "The quick brown fox",   font: .ceciliasNotesTitle2)
                typeRow(".ceciliasNotesHeadline", sample: "The quick brown fox",   font: .ceciliasNotesHeadline)
                typeRow(".ceciliasNotesBody",     sample: "The quick brown fox",   font: .ceciliasNotesBody)
                typeRow(".ceciliasNotesCallout",  sample: "The quick brown fox",   font: .ceciliasNotesCallout)
                typeRow(".ceciliasNotesSubhead",  sample: "The quick brown fox",   font: .ceciliasNotesSubhead)
                typeRow(".ceciliasNotesFootnote", sample: "The quick brown fox",   font: .ceciliasNotesFootnote)
                typeRow(".ceciliasNotesCaption",  sample: "The quick brown fox",   font: .ceciliasNotesCaption)
                typeRow(".ceciliasNotesMono",     sample: "let x: Int = 42",       font: .ceciliasNotesMono)
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var spacingSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("Spacing & Radius")

            VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
                ForEach([
                    ("micro", CeciliasNotes.Spacing.micro),
                    ("xs",    CeciliasNotes.Spacing.xs),
                    ("sm",    CeciliasNotes.Spacing.sm),
                    ("md",    CeciliasNotes.Spacing.md),
                    ("lg",    CeciliasNotes.Spacing.lg),
                    ("xl",    CeciliasNotes.Spacing.xl),
                    ("xxl",   CeciliasNotes.Spacing.xxl),
                ], id: \.0) { name, value in
                    HStack(spacing: CeciliasNotes.Spacing.sm) {
                        Text(".\(name)")
                            .font(.ceciliasNotesMono)
                            .foregroundColor(theme.foregroundMuted)
                            .frame(width: 80, alignment: .leading)
                        Rectangle()
                            .fill(theme.accent)
                            .frame(width: value, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
                        Text("\(Int(value))pt")
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(theme.foregroundSubtle)
                    }
                }
            }

            Text("Radius tokens")
                .font(.ceciliasNotesFootnote)
                .foregroundColor(theme.foregroundSubtle)
                .padding(.top, CeciliasNotes.Spacing.sm)

            HStack(spacing: CeciliasNotes.Spacing.md) {
                ForEach([
                    ("sm",   CeciliasNotes.Radius.sm),
                    ("md",   CeciliasNotes.Radius.md),
                    ("lg",   CeciliasNotes.Radius.lg),
                    ("xl",   CeciliasNotes.Radius.xl),
                ], id: \.0) { name, value in
                    VStack(spacing: CeciliasNotes.Spacing.xs) {
                        RoundedRectangle(cornerRadius: value, style: .continuous)
                            .fill(theme.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: value, style: .continuous)
                                    .strokeBorder(theme.borderDefault, lineWidth: 0.5)
                            )
                            .frame(width: 56, height: 56)
                        Text(".\(name)")
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(theme.foregroundSubtle)
                    }
                }
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var buttonsSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("CeciliasNotesButton")

            VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
                HStack(spacing: CeciliasNotes.Spacing.sm) {
                    CeciliasNotesButton("Primary", style: .primary) {}
                    CeciliasNotesButton("Secondary", style: .secondary) {}
                    CeciliasNotesButton("Ghost", style: .ghost) {}
                }
                HStack(spacing: CeciliasNotes.Spacing.sm) {
                    CeciliasNotesButton("Destructive", style: .destructive) {}
                    CeciliasNotesButton("Loading", style: .primary, isLoading: isButtonLoading) {
                        isButtonLoading.toggle()
                    }
                    .onAppear {
                        Task {
                            try? await Task.sleep(for: .seconds(0.5))
                            isButtonLoading = true
                        }
                    }
                }
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var textFieldSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("CeciliasNotesTextField")
            CeciliasNotesTextField("Note title…", text: $sampleText, icon: "pencil", maxLength: 80)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var badgesSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("CeciliasNotesBadge")
            HStack(spacing: CeciliasNotes.Spacing.sm) {
                CeciliasNotesBadge("Default", style: .default)
                CeciliasNotesBadge("Accent",  style: .accent)
                CeciliasNotesBadge("42",      style: .count)
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var emptyStateSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("CeciliasNotesEmptyState")
            HStack {
                Spacer()
                CeciliasNotesEmptyState(
                    icon: "doc.text",
                    title: "No notes yet",
                    subtitle: "Tap the pen to start your first note.",
                    action: (label: "New Note", handler: {})
                )
                Spacer()
            }
            .ceciliasNotesCard()
            .padding(.vertical, CeciliasNotes.Spacing.md)
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var themeSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("Theme")

            HStack(spacing: CeciliasNotes.Spacing.md) {
                ForEach(Theme.all) { theme in
                    themeCard(theme)
                }
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    private var iconPreviewSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("App Icon")
            IconPreviewView()
        }
    }

    private var animationSection: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.md) {
            sectionHeader("Animation Presets")
            Text("Reduce Motion: \(UIAccessibility.isReduceMotionEnabled ? "ON — springs replaced with crossfade" : "OFF — springs active")")
                .font(.ceciliasNotesFootnote)
                .foregroundColor(UIAccessibility.isReduceMotionEnabled ? theme.danger : theme.foregroundMuted)

            ForEach([
                ("snappy",  CeciliasNotesSpring.snappy,  "response 0.28 / damping 0.82"),
                ("smooth",  CeciliasNotesSpring.smooth,  "response 0.40 / damping 0.85"),
                ("bouncy",  CeciliasNotesSpring.bouncy,  "response 0.35 / damping 0.70"),
                ("precise", CeciliasNotesSpring.precise, "response 0.22 / damping 0.90"),
            ], id: \.0) { name, animation, description in
                AnimationRow(name: name, animation: animation, description: description)
            }
        }
        .padding(.horizontal, CeciliasNotes.Spacing.md)
    }

    // MARK: Helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.ceciliasNotesHeadline)
            .foregroundColor(theme.foreground)
    }

    private func colorGroup(_ groupName: String, swatches: [(String, Color)]) -> some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.xs) {
            Text(groupName)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CeciliasNotes.Spacing.sm) {
                    ForEach(swatches, id: \.0) { name, color in
                        colorSwatch(name: name, color: color)
                    }
                }
            }
        }
    }

    private func colorSwatch(name: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.xs) {
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .fill(color)
                .overlay(
                    RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                        .strokeBorder(theme.borderDefault, lineWidth: 0.5)
                )
                .frame(width: 64, height: 40)

            Text(name)
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
                .lineLimit(2)
                .frame(width: 64, alignment: .leading)
        }
    }

    private func typeRow(_ token: String, sample: String, font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: CeciliasNotes.Spacing.md) {
            Text(token)
                .font(.ceciliasNotesMono)
                .foregroundColor(theme.foregroundSubtle)
                .frame(width: 120, alignment: .leading)
            Text(sample)
                .font(font)
                .foregroundColor(theme.foreground)
        }
    }

    private func themeCard(_ theme: Theme) -> some View {
        let isSelected = themeManager.current.id == theme.id

        return Button {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                themeManager.setTheme(theme)
            }
        } label: {
            VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
                // Mini preview — reads directly from Theme struct fields
                // (no preview helper indirection in the new design).
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                    .fill(theme.background)
                    .frame(height: 72)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 4) {
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(theme.foreground)
                                .frame(width: 48, height: 6)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(theme.foreground.opacity(0.4))
                                .frame(width: 64, height: 4)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(theme.accent)
                                .frame(width: 32, height: 4)
                        }
                        .padding(CeciliasNotes.Spacing.sm)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accent : theme.borderDefault,
                                lineWidth: isSelected ? 2 : 0.5
                            )
                    )

                Text(theme.displayName)
                    .font(.ceciliasNotesSubhead)
                    .foregroundColor(isSelected ? theme.foreground : theme.foregroundMuted)
            }
        }
        .buttonStyle(.ceciliasNotesPressable)
    }
}

// MARK: - AnimationRow

private struct AnimationRow: View {
    let name: String
    let animation: Animation
    let description: String
    @Environment(\.theme) private var theme

    @State private var isAnimating = false

    var body: some View {
        HStack(spacing: CeciliasNotes.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(".\(name)")
                    .font(.ceciliasNotesMono)
                    .foregroundColor(theme.foregroundMuted)
                Text(description)
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
            }
            .frame(width: 180, alignment: .leading)

            Spacer()

            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous)
                .fill(theme.accent)
                .frame(width: 32, height: 32)
                .offset(x: isAnimating ? 24 : -24)
                .ceciliasNotesAnimation(animation, value: isAnimating)

            Spacer()

            Button {
                isAnimating.toggle()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .fontWeight(.medium)
                    .foregroundColor(theme.accent)
                    .frame(width: 44, height: 44)
            }
        }
        .padding(CeciliasNotes.Spacing.sm)
        .ceciliasNotesCard()
        .onAppear {
            Task {
                try? await Task.sleep(for: .seconds(0.6))
                isAnimating = true
            }
        }
    }
}

// MARK: - Preview

#Preview {
    StyleGuideView()
        .environmentObject(ThemeManager())
}
#endif

import SwiftUI

/// Picker for the eight `NotebookCoverTone` options.
///
/// Two entry points:
///  • Notebook card → context menu → "Change Cover" — opened as a popover.
///  • Editor toolbar → ⋯ → "Cover" — opened as a popover.
///
/// The picker writes the chosen tone via `CoverToneStore` (the same
/// side channel `Notebook.coverTone` reads from) and immediately
/// dismisses. The caller refreshes its data source on dismissal.
struct CoverTonePickerView: View {
    let notebook: Notebook
    let onDismiss: () -> Void

    @State private var selected: NotebookCoverTone
    @Environment(\.theme) private var theme

    init(notebook: Notebook, onDismiss: @escaping () -> Void) {
        self.notebook  = notebook
        self.onDismiss = onDismiss
        self._selected = State(initialValue: notebook.coverTone)
    }

    /// Display order matches the spec's gallery: light tones first
    /// (parchment / studio white / ash), the named-mood family next
    /// (coal / midnight / moss / dusk), then `inkBlack` last — it's the
    /// only tone the user must explicitly choose, never auto-assigned.
    private static let tones: [NotebookCoverTone] = [
        .parchment, .studioWhite, .ash, .coal,
        .midnight, .moss, .dusk, .inkBlack
    ]

    private static let columns = Array(
        repeating: GridItem(.fixed(60), spacing: 14),
        count: 4
    )

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("cover")
                .font(.system(size: 7.5, weight: .regular))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)

            LazyVGrid(columns: Self.columns, spacing: 14) {
                ForEach(Self.tones, id: \.self) { tone in
                    toneCell(tone)
                }
            }

            Text("tap to change · app assigns by default")
                .font(.system(size: 9, weight: .regular).italic())
                .foregroundStyle(theme.recessiveTertiary)
        }
        .padding(20)
        .background(theme.surfaceElevated)
        .presentationCompactAdaptation(.popover)
    }

    // MARK: Cell

    @ViewBuilder
    private func toneCell(_ tone: NotebookCoverTone) -> some View {
        let isSelected = tone == selected

        VStack(spacing: 6) {
            ZStack {
                tone.background

                GhostLetter(
                    character: "a",
                    size: 36,
                    onDarkBackground: !tone.isLight
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 6, y: 6)
                .clipped()
            }
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accent
                            : (tone.requiresBorder ? Color(hex: "#ebebeb") : Color.clear),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )

            Text(displayName(for: tone))
                .font(.system(size: 8, weight: .regular))
                .foregroundStyle(theme.recessiveTertiary)
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            selected = tone
            CoverToneStore.setTone(tone, for: notebook.id)
            HapticManager.shared.toolSwitched()
            // Brief delay so the user sees the new selection ring
            // before the popover dismisses — avoids a flash-and-gone.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                onDismiss()
            }
        }
        .accessibilityElement()
        .accessibilityLabel(displayName(for: tone))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: Naming

    private func displayName(for tone: NotebookCoverTone) -> String {
        switch tone {
        case .parchment:    return "Parchment"
        case .studioWhite:  return "Studio White"
        case .ash:          return "Ash"
        case .coal:         return "Coal"
        case .midnight:     return "Midnight"
        case .moss:         return "Moss"
        case .dusk:         return "Dusk"
        case .inkBlack:     return "Ink Black"
        }
    }
}

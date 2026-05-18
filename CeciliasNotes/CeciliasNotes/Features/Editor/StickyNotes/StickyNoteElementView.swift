import SwiftData
import SwiftUI

/// Renders one V6 `PageElement` of kind `.stickyNote` as a coloured
/// card with in-place text editing. Follows the template established
/// by `TextElementView` / `ImageElementView` / `HighlightElementView`,
/// with two intentional UX deviations from the text element:
///
///   • **Single-tap-to-edit.** Sticky notes are quick-capture by
///     nature — a tap on a sticky drops the keyboard immediately
///     rather than requiring a tap-to-select then tap-to-edit
///     two-step. Documented in Step 7 design notes.
///   • **Long-press-to-select.** The "manipulate without editing"
///     gesture is long-press: it surfaces the selection chrome
///     (color picker + delete) without entering the keyboard. Tap
///     edits; long-press selects.
///
/// Card design: opaque colour from `theme.stickyNotePalette`,
/// rounded corners, soft drop shadow. Body-size text in a fixed
/// dark colour that reads on every palette variant — no per-colour
/// contrast logic.
struct StickyNoteElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: StickyNoteContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    @Binding var isEditing: Bool
    let onDelete: () -> Void
    let onRequestSelect: () -> Void
    let onRequestEdit: () -> Void

    @Environment(\.theme) private var theme

    // MARK: - Layout

    private var width: CGFloat {
        element.normalizedWidth * pageSize.width
    }
    private var height: CGFloat {
        element.normalizedHeight * pageSize.height
    }
    private var centerX: CGFloat {
        (element.normalizedX + element.normalizedWidth  / 2) * pageSize.width
    }
    private var centerY: CGFloat {
        (element.normalizedY + element.normalizedHeight / 2) * pageSize.height
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            card
            if isEditing {
                StickyTextEditor(
                    text: $content.text,
                    isEditing: $isEditing,
                    textColor: UIColor(stickyTextColor)
                )
                .padding(12)
            } else {
                Text(content.text.isEmpty ? "tap to edit" : content.text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(
                        content.text.isEmpty
                            ? stickyTextColor.opacity(0.45)
                            : stickyTextColor
                    )
                    .padding(12)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .topLeading
                    )
            }
        }
        .frame(width: width, height: height)
        .overlay(selectionChrome)
        .overlay(alignment: .top) { colorPickerStrip }
        .position(x: centerX, y: centerY)
        .rotationEffect(.radians(element.rotation))
        // Tap → edit. Long-press → select. The order matters: the
        // tap recognizer is registered first so SwiftUI prefers it
        // for short touches; the long-press wins for sustained.
        .onTapGesture { onRequestEdit() }
        .onLongPressGesture(minimumDuration: 0.35) { onRequestSelect() }
        .onChange(of: content.text) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
        .onChange(of: content.colorVariant) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
    }

    // MARK: - Card

    private var card: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(cardColor)
            .shadow(
                color: .black.opacity(0.18),
                radius: 4,
                x: 0,
                y: 2
            )
    }

    private var cardColor: Color {
        theme.stickyNotePalette[content.colorVariant]
            ?? theme.stickyNotePalette["yellow"]
            ?? .yellow
    }

    /// Fixed dark grey reads on every sticky-palette variant in
    /// both themes — the palette was tuned to avoid the per-colour
    /// contrast-flip branching legacy chrome accumulates.
    private var stickyTextColor: Color {
        Color(red: 0.15, green: 0.15, blue: 0.15)
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private var selectionChrome: some View {
        if isSelected && !isEditing {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        theme.accent,
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button(action: onDelete) {
                            Image(systemName: "trash.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(theme.accent)
                                .background(
                                    Circle().fill(theme.surfaceElevated)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
            }
        }
    }

    // MARK: - Color picker

    /// Horizontal swatch row that floats above the sticky when
    /// selected (and not editing). Positioned via `.overlay
    /// (alignment: .top)` with a negative offset so it sits clear
    /// of the card edge.
    @ViewBuilder
    private var colorPickerStrip: some View {
        if isSelected && !isEditing {
            HStack(spacing: 8) {
                ForEach(StickyNoteCommit.paletteKeys, id: \.self) { key in
                    swatch(key: key)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(theme.surfaceElevated)
            )
            .overlay(
                Capsule().stroke(theme.borderSubtle, lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .offset(y: -36)
        }
    }

    private func swatch(key: String) -> some View {
        let isActive = content.colorVariant == key
        let fill = theme.stickyNotePalette[key] ?? .yellow
        return Circle()
            .fill(fill)
            .frame(width: 22, height: 22)
            .overlay(
                Circle().stroke(
                    isActive ? theme.accent : theme.borderSubtle,
                    lineWidth: isActive ? 2 : 0.5
                )
            )
            .contentShape(Circle())
            .onTapGesture { content.colorVariant = key }
    }
}

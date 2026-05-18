import SwiftUI

/// Tiny three-button row for picking a `TextSize`. Shown above the
/// currently-selected text element (cursor mode, not editing) so the
/// user can switch between Small / Body / Heading without opening a
/// menu. Selection state mirrors `content.size`.
struct TextSizePickerView: View {

    @Binding var size: TextSize
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TextSize.allCases, id: \.self) { option in
                button(for: option)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surfaceElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.08), radius: 6, x: 0, y: 1)
        )
    }

    private func button(for option: TextSize) -> some View {
        let isActive = size == option
        return Button {
            size = option
            HapticManager.shared.toolSwitched()
        } label: {
            Image(systemName: option.systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(isActive ? theme.accent : theme.foregroundMuted)
                .frame(width: 32, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? theme.accent.opacity(0.12) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Text size: \(option.displayName)")
    }
}

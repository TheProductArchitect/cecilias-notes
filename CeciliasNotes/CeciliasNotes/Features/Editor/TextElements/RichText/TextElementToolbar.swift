import SwiftUI
import UIKit

/// SwiftUI formatting toolbar hosted as the `inputAccessoryView` of
/// a focused text block's UITextView. Curated controls — toggles for
/// B/I/U/S, heading menu, size segmented control, family menu,
/// alignment segmented control, color swatch row, list toggles.
///
/// All actions flow through `RichTextController`, which mutates the
/// attached UITextView. Active-state is derived from
/// `controller.currentAttributes`, which the coordinator refreshes
/// on every selection change.
struct TextElementToolbar: View {
    @ObservedObject var controller: RichTextController
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    private var swatches: [UIColor] {
        colorScheme == .dark
            ? RichTextColorPalette.swatchesDark
            : RichTextColorPalette.swatchesLight
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                styleToggles
                divider
                headingMenu
                sizePicker
                familyMenu
                divider
                alignmentPicker
                listToggles
                divider
                colorSwatches
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(
            Rectangle()
                .fill(theme.surfaceElevated)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(theme.hairline)
                        .frame(height: 0.5)
                }
        )
        .frame(height: 44)
    }

    // MARK: - Pieces

    private var styleToggles: some View {
        HStack(spacing: 6) {
            iconToggle(systemImage: "bold",          isOn: controller.currentAttributes.isBold)         { controller.toggleBold() }
            iconToggle(systemImage: "italic",        isOn: controller.currentAttributes.isItalic)       { controller.toggleItalic() }
            iconToggle(systemImage: "underline",     isOn: controller.currentAttributes.isUnderline)    { controller.toggleUnderline() }
            iconToggle(systemImage: "strikethrough", isOn: controller.currentAttributes.isStrikethrough){ controller.toggleStrikethrough() }
        }
    }

    private var headingMenu: some View {
        Menu {
            ForEach(RichTextHeading.allCases, id: \.self) { h in
                Button {
                    controller.setHeading(h)
                } label: {
                    HStack {
                        Text(h.label)
                        if controller.currentAttributes.heading == h {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.currentAttributes.heading.label)
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.recessiveQuinary.opacity(0.5))
            )
        }
    }

    private var sizePicker: some View {
        HStack(spacing: 0) {
            ForEach(RichTextSize.allCases, id: \.self) { s in
                Button { controller.setSize(s) } label: {
                    Text(s.label)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            controller.currentAttributes.size == s
                                ? Color.white
                                : theme.foreground
                        )
                        .frame(width: 26, height: 28)
                        .background(
                            controller.currentAttributes.size == s
                                ? theme.accent
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.recessiveQuinary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var familyMenu: some View {
        Menu {
            ForEach(RichTextFontFamily.allCases, id: \.self) { f in
                Button {
                    controller.setFamily(f)
                } label: {
                    HStack {
                        Text(f.label)
                        if controller.currentAttributes.family == f {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(controller.currentAttributes.family.label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(theme.recessiveQuinary.opacity(0.5))
            )
        }
    }

    private var alignmentPicker: some View {
        HStack(spacing: 0) {
            ForEach(RichTextAlignment.allCases, id: \.self) { a in
                Button { controller.setAlignment(a) } label: {
                    Image(systemName: a.systemImage)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(
                            controller.currentAttributes.alignment == a
                                ? Color.white
                                : theme.foreground
                        )
                        .frame(width: 30, height: 28)
                        .background(
                            controller.currentAttributes.alignment == a
                                ? theme.accent
                                : Color.clear
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(theme.recessiveQuinary.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(theme.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var listToggles: some View {
        HStack(spacing: 6) {
            iconToggle(systemImage: "list.bullet",
                       isOn: controller.currentAttributes.listMode == .bullet) {
                controller.toggleBullet()
            }
            iconToggle(systemImage: "list.number",
                       isOn: controller.currentAttributes.listMode == .numbered) {
                controller.toggleNumbered()
            }
        }
    }

    private var colorSwatches: some View {
        HStack(spacing: 6) {
            // Inherit-ink swatch (clears the foreground attribute).
            Button { controller.setForeground(nil) } label: {
                Circle()
                    .fill(Color.clear)
                    .overlay(
                        Circle().stroke(theme.borderDefault, lineWidth: 1)
                    )
                    .overlay(
                        Image(systemName: "slash.circle")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.foregroundSubtle)
                    )
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)

            ForEach(Array(swatches.enumerated()), id: \.offset) { _, color in
                Button { controller.setForeground(color) } label: {
                    Circle()
                        .fill(Color(uiColor: color))
                        .overlay(
                            Circle().stroke(
                                isSelected(color) ? theme.accent : Color.black.opacity(0.1),
                                lineWidth: isSelected(color) ? 2 : 0.5
                            )
                        )
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func isSelected(_ color: UIColor) -> Bool {
        guard let fg = controller.currentAttributes.foreground else { return false }
        return fg.isApproximately(color)
    }

    // MARK: - Atoms

    private func iconToggle(
        systemImage: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? Color.white : theme.foreground)
                .frame(width: 30, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isOn ? theme.accent : theme.recessiveQuinary.opacity(0.5))
                )
        }
        .buttonStyle(.plain)
    }

    private var divider: some View {
        Rectangle()
            .fill(theme.hairline)
            .frame(width: 0.5, height: 22)
    }
}

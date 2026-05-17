import SwiftUI

// MARK: - CeciliasNotesButton

public enum CeciliasNotesButtonStyle {
    case primary
    case secondary
    case ghost
    case destructive
}

public struct CeciliasNotesButton: View {
    let label: String
    let style: CeciliasNotesButtonStyle
    let isLoading: Bool
    let action: () -> Void

    public init(
        _ label: String,
        style: CeciliasNotesButtonStyle = .primary,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.style = style
        self.isLoading = isLoading
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(foregroundColor)
                        .scaleEffect(0.85)
                } else {
                    Text(label)
                        .font(.ceciliasNotesHeadline)
                        .foregroundColor(foregroundColor)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .background(background)
            .overlay(border)
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.md, style: .continuous))
        }
        .disabled(isLoading)
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .primary:
            Color.inkAccentPrimary
        case .secondary:
            Color.clear
        case .ghost:
            Color.clear
        case .destructive:
            Color.inkDestructive
        }
    }

    @ViewBuilder private var border: some View {
        switch style {
        case .secondary:
            RoundedRectangle(cornerRadius: CeciliasNotes.Radius.md, style: .continuous)
                .strokeBorder(Color.inkBorderDefault, lineWidth: 0.5)
        default:
            EmptyView()
        }
    }

    private var foregroundColor: Color {
        switch style {
        case .primary:     return .white
        case .secondary:   return .inkTextPrimary
        case .ghost:       return .inkAccentPrimary
        case .destructive: return .white
        }
    }
}

// MARK: - CeciliasNotesTextField

public struct CeciliasNotesTextField: View {
    let placeholder: String
    @Binding var text: String
    let icon: String?
    let maxLength: Int?

    @FocusState private var isFocused: Bool

    public init(
        _ placeholder: String,
        text: Binding<String>,
        icon: String? = nil,
        maxLength: Int? = nil
    ) {
        self.placeholder = placeholder
        self._text = text
        self.icon = icon
        self.maxLength = maxLength
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: CeciliasNotes.Spacing.sm) {
                if let icon {
                    Image(systemName: icon)
                        .symbolRenderingMode(.hierarchical)
                        .imageScale(.medium)
                        .fontWeight(.medium)
                        .foregroundColor(.inkTextTertiary)
                        .frame(width: 20)
                }

                TextField(placeholder, text: $text)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(.inkTextPrimary)
                    .focused($isFocused)
                    .frame(minHeight: 44)

                if let maxLength {
                    Text("\(text.count)/\(maxLength)")
                        .font(.ceciliasNotesCaption)
                        .foregroundColor(text.count >= maxLength ? .inkDestructive : .inkTextTertiary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.sm)

            Rectangle()
                .fill(isFocused ? Color.inkAccentPrimary : Color.inkBorderDefault)
                .frame(height: 0.5)
                .ceciliasNotesAnimation(CeciliasNotesSpring.precise, value: isFocused)
        }
        .onChange(of: text) { _, newValue in
            if let maxLength, newValue.count > maxLength {
                text = String(newValue.prefix(maxLength))
            }
        }
    }
}

// MARK: - .ceciliasNotesCard() modifier

private struct CeciliasNotesCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(Color.inkBackgroundElevated)
            .overlay(
                RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous)
                    .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
    }
}

public extension View {
    func ceciliasNotesCard() -> some View {
        modifier(CeciliasNotesCardModifier())
    }
}

// MARK: - CeciliasNotesBadge

public enum CeciliasNotesBadgeStyle {
    case `default`
    case accent
    case count
}

public struct CeciliasNotesBadge: View {
    let text: String
    let style: CeciliasNotesBadgeStyle

    public init(_ text: String, style: CeciliasNotesBadgeStyle = .default) {
        self.text = text
        self.style = style
    }

    public var body: some View {
        Text(text)
            .font(style == .count ? .ceciliasNotesCaption : .ceciliasNotesFootnote)
            .fontWeight(style == .count ? .semibold : .regular)
            .foregroundColor(foregroundColor)
            .padding(.horizontal, style == .count ? CeciliasNotes.Spacing.xs : CeciliasNotes.Spacing.sm)
            .padding(.vertical, CeciliasNotes.Spacing.micro)
            .background(background)
            .clipShape(Capsule())
    }

    private var foregroundColor: Color {
        switch style {
        case .default: return .inkTextSecondary
        case .accent:  return .inkAccentPrimary
        case .count:   return .white
        }
    }

    @ViewBuilder private var background: some View {
        switch style {
        case .default: Color.inkBackgroundTertiary
        case .accent:  Color.inkAccentSecondary
        case .count:   Color.inkAccentPrimary
        }
    }
}

// MARK: - CeciliasNotesDivider

public struct CeciliasNotesDivider: View {
    public init() {}

    public var body: some View {
        Rectangle()
            .fill(Color.inkBorderSubtle)
            .frame(maxWidth: .infinity)
            .frame(height: 0.5)
    }
}

// MARK: - CeciliasNotesEmptyState

public struct CeciliasNotesEmptyState: View {
    let icon: String
    let title: String
    let subtitle: String
    let action: (label: String, handler: () -> Void)?

    public init(
        icon: String,
        title: String,
        subtitle: String,
        action: (label: String, handler: () -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }

    public var body: some View {
        VStack(spacing: CeciliasNotes.Spacing.md) {
            Image(systemName: icon)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 44))
                .fontWeight(.medium)
                .foregroundColor(.inkTextTertiary)

            VStack(spacing: CeciliasNotes.Spacing.xs) {
                Text(title)
                    .font(.ceciliasNotesTitle2)
                    .foregroundColor(.inkTextSecondary)
                    .multilineTextAlignment(.center)

                Text(subtitle)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(.inkTextTertiary)
                    .multilineTextAlignment(.center)
            }

            if let action {
                CeciliasNotesButton(action.label, style: .primary, action: action.handler)
                    .padding(.top, CeciliasNotes.Spacing.sm)
            }
        }
        .padding(CeciliasNotes.Spacing.xl)
        .frame(maxWidth: 320)
    }
}

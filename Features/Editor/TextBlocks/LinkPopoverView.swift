import SwiftUI

// MARK: - LinkPopoverView

/// Compact popover for adding or editing a hyperlink on the selected text.
struct LinkPopoverView: View {

    @Binding var isPresented: Bool
    let existingURL: URL?
    let onApply: (URL) -> Void
    let onRemove: () -> Void

    @State private var urlText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            Text(existingURL == nil ? "Add Link" : "Edit Link")
                .font(.inkSubhead)
                .foregroundColor(.inkTextPrimary)

            HStack(spacing: Ink.Spacing.xs) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundColor(.inkTextTertiary)

                TextField("https://", text: $urlText)
                    .font(.inkBody)
                    .foregroundColor(.inkTextPrimary)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isFocused)
                    .onSubmit { tryApply() }
            }
            .padding(Ink.Spacing.sm)
            .background(Color.inkBackgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))

            HStack(spacing: Ink.Spacing.sm) {
                if existingURL != nil {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        isPresented = false
                    }
                    .font(.inkCaption)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .font(.inkBody)
                .foregroundColor(.inkTextSecondary)

                Button("Apply") {
                    tryApply()
                }
                .font(.inkBody)
                .foregroundColor(.inkAccentPrimary)
                .disabled(!isValidURL)
            }
        }
        .padding(Ink.Spacing.md)
        .frame(width: 300)
        .onAppear {
            urlText   = existingURL?.absoluteString ?? ""
            isFocused = true
        }
    }

    private var isValidURL: Bool {
        guard let u = URL(string: urlText) else { return false }
        return u.scheme != nil
    }

    private func tryApply() {
        guard let url = URL(string: urlText), url.scheme != nil else { return }
        onApply(url)
        isPresented = false
    }
}

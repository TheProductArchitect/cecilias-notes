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
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            Text(existingURL == nil ? "Add Link" : "Edit Link")
                .font(.ceciliasNotesSubhead)
                .foregroundColor(.inkTextPrimary)

            HStack(spacing: CeciliasNotes.Spacing.xs) {
                Image(systemName: "link")
                    .font(.system(size: 14))
                    .foregroundColor(.inkTextTertiary)

                TextField("https://", text: $urlText)
                    .font(.ceciliasNotesBody)
                    .foregroundColor(.inkTextPrimary)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .focused($isFocused)
                    .onSubmit { tryApply() }
            }
            .padding(CeciliasNotes.Spacing.sm)
            .background(Color.inkBackgroundSecondary)
            .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))

            HStack(spacing: CeciliasNotes.Spacing.sm) {
                if existingURL != nil {
                    Button("Remove", role: .destructive) {
                        onRemove()
                        isPresented = false
                    }
                    .font(.ceciliasNotesCaption)
                }

                Spacer()

                Button("Cancel") {
                    isPresented = false
                }
                .font(.ceciliasNotesBody)
                .foregroundColor(.inkTextSecondary)

                Button("Apply") {
                    tryApply()
                }
                .font(.ceciliasNotesBody)
                .foregroundColor(.inkAccentPrimary)
                .disabled(!isValidURL)
            }
        }
        .padding(CeciliasNotes.Spacing.md)
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

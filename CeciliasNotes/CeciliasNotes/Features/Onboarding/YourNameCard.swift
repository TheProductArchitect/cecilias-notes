import SwiftUI

/// Settings → About → Your Name row. Same validation rules as onboarding,
/// smaller wordmark above the field, commits on submit / focus loss.
struct YourNameCard: View {
    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""
    @State private var buffer:           String = ""
    @State private var validationError: Bool   = false
    @FocusState private var focused:    Bool
    @Environment(\.theme) private var theme

    private var previewLetter: Character {
        let firstChar = buffer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        return firstChar ?? "c"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            HStack(alignment: .center, spacing: CeciliasNotes.Spacing.md) {
                BrandWordmark(letter: previewLetter, size: 36)
                    .ceciliasNotesAnimation(CeciliasNotesSpring.snappy, value: previewLetter)
                    .frame(width: 56, height: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Name")
                        .font(.ceciliasNotesBody)
                        .foregroundColor(theme.foreground)
                    TextField("Add your name", text: $buffer)
                        .font(.ceciliasNotesSubhead)
                        .foregroundColor(theme.foregroundMuted)
                        .focused($focused)
#if os(iOS)
                        .submitLabel(.done)
                        .textInputAutocapitalization(.words)
#endif
                        .autocorrectionDisabled()
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                        .onChange(of: buffer) { _, _ in
                            if validationError { validationError = false }
                        }
                }
            }
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)

            Group {
                if validationError {
                    Text("Letters only, please.")
                        .foregroundColor(theme.danger)
                } else {
                    Text("Personalises your home screen greeting.")
                        .foregroundColor(theme.foregroundSubtle)
                }
            }
            .font(.ceciliasNotesCaption)
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.bottom, CeciliasNotes.Spacing.sm)
        }
        .onAppear { buffer = userName }
    }

    private func commit() {
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            guard !userName.isEmpty else { return }
            userName = ""
            buffer   = ""
            validationError = false
            updateAppIcon(for: "")
            PersonalIdentity.mirrorNameToAppGroup("")
            return
        }

        switch validateName(buffer) {
        case .invalid:
            validationError = true
            HapticManager.shared.contextMenuOpened()
        case .accept(let firstWord):
            guard firstWord != userName else {
                buffer = firstWord
                return
            }
            userName = firstWord
            buffer   = firstWord
            updateAppIcon(for: firstWord)
            PersonalIdentity.mirrorNameToAppGroup(firstWord)
        }
    }
}

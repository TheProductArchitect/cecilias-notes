import SwiftUI

/// Mac onboarding — a single personalisation moment mirroring the
/// iPad's `OnboardingView`. The whole point is to capture the user's
/// name so `BrandWordmark` renders `[name]'s notes·` throughout the
/// app; without it the wordmark falls back to the fallback "cecilia's"
/// and the personalisation the app is built around never activates.
///
/// Three panes, same voice as iPad:
///   1. Welcome — live wordmark preview keyed off the character the
///      user's typing, matter-of-fact copy, name field.
///   2. Sync — one-line iCloud reminder + Continue.
///   3. Done — the constraint one-liner ("Handwriting stays on iPad")
///      so the user knows the pill they will never see on Mac.
///
/// State is kept as tight as the iPad: `PersonalIdentity.nameKey`
/// (mirrored into the App Group so the widget on iPhone / iPad
/// updates with the same possessive), `app.onboarding.completed`,
/// and `PersonalIdentity.mirrorNameToAppGroup(...)` to nudge
/// cross-device parity.
struct MacOnboardingView: View {
    @Binding var isPresented: Bool
    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""
    @Environment(\.theme) private var theme

    @State private var step: Step = .name
    @State private var inputText: String = ""
    @State private var validationError = false
    @FocusState private var fieldFocused: Bool

    enum Step { case name, sync, done }

    /// Live preview letter — first character of what the user is
    /// currently typing (or a soft fallback "c" while empty). The
    /// iPad picks this from `previewLetter` inside `OnboardingView`;
    /// we replicate the same visual so the moment reads identically.
    private var previewLetter: Character {
        let stripped = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.first ?? "c"
    }

    private var isValidInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            Group {
                switch step {
                case .name:  nameStep
                case .sync:  syncStep
                case .done:  doneStep
                }
            }
            .transition(.opacity)

            Spacer(minLength: 0)

            navigation
                .padding(.horizontal, 32)
                .padding(.bottom, 24)
        }
        .frame(width: 520, height: 440)
        .background(theme.background)
        .animation(.easeInOut(duration: 0.18), value: step)
        .onAppear {
            // Prefill the field when the user re-opens onboarding
            // via Settings → Appearance → "Show onboarding again".
            inputText = userName
            fieldFocused = true
        }
    }

    // MARK: - Step 1 — name

    private var nameStep: some View {
        VStack(spacing: 32) {
            // Live wordmark preview — the moment that sells
            // personalisation. Same size + weight as the iPad's
            // 96pt preview.
            BrandWordmark(letter: previewLetter, size: 96)
                .frame(height: 120)
                .accessibilityLabel("Wordmark preview")

            VStack(spacing: 12) {
                Text("What should we call this?")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.foreground)

                TextField("your name", text: $inputText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(theme.foreground)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(theme.borderSubtle)
                            .frame(height: 1)
                    }
                    .onChange(of: inputText) { _, _ in
                        if validationError { validationError = false }
                    }
                    .onSubmit { advanceFromNameStep() }

                Text(validationError ? "Letters only, please." : " ")
                    .font(.system(size: 12))
                    .foregroundStyle(validationError ? theme.danger : .clear)
                    .frame(height: 16)
            }
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 2 — sync

    private var syncStep: some View {
        VStack(spacing: 20) {
            Text("hello, \(inputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).")
                .font(.system(size: 34, weight: .heavy))
                .tracking(-0.6)
                .foregroundStyle(theme.foreground)
                .multilineTextAlignment(.center)

            VStack(spacing: 6) {
                Text("Your notebooks sync through iCloud.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.foregroundMuted)
                Text("Sign in on this Mac to keep iPad and Mac in step.")
                    .font(.system(size: 15))
                    .foregroundStyle(theme.foregroundMuted)
            }
            .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Step 3 — done

    private var doneStep: some View {
        VStack(spacing: 18) {
            BrandWordmark(userName: inputText.trimmingCharacters(in: .whitespacesAndNewlines))
                .frame(height: 88)

            Text("Handwriting stays on iPad. Read strokes here, edit them there. Everything else — typed text, PDFs, images, quizzes, search — lives on Mac too.")
                .font(.system(size: 14))
                .foregroundStyle(theme.foregroundMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .padding(.horizontal, 32)
    }

    // MARK: - Navigation

    private var navigation: some View {
        HStack {
            if step != .name {
                Button("back") { back() }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.recessivePrimary)
                    .font(.system(size: 13))
            }
            Spacer()
            Button(step == .done ? "done" : "continue") { forward() }
                .keyboardShortcut(.defaultAction)
                .disabled(step == .name && !isValidInput)
                .opacity(step == .name && !isValidInput ? 0.4 : 1)
        }
    }

    private func back() {
        switch step {
        case .name: break
        case .sync: step = .name
        case .done: step = .sync
        }
    }

    private func forward() {
        switch step {
        case .name: advanceFromNameStep()
        case .sync: step = .done
        case .done: finish()
        }
    }

    // MARK: - Commit

    /// Validate + commit the name field, then advance. Uses the same
    /// `validateName` gate as iPad so the two platforms enforce the
    /// same "letters only, first word wins" rules.
    private func advanceFromNameStep() {
        guard isValidInput else { return }
        switch validateName(inputText) {
        case .invalid:
            validationError = true
        case .accept(let firstWord):
            userName = firstWord
            // Mirror to the App Group so the iPhone widget's
            // wordmark picks up the possessive within a couple of
            // seconds — same call the iPad's `commit()` makes.
            PersonalIdentity.mirrorNameToAppGroup(firstWord)
            step = .sync
        }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: PersonalIdentity.onboardingCompletedKey)
        UserDefaults.standard.synchronize()
        isPresented = false
    }
}

import SwiftUI

// MARK: - OnboardingView

/// Full-screen first-launch experience that asks for the user's name and
/// personalises the home greeting + app icon. Mounted as a fullScreenCover
/// from `LibraryView` (or higher) gated by `app.onboarding.completed`.
///
/// Flow
///   1. User types — wordmark preview at the top updates live to their
///      first letter (defaults to `i` while empty).
///   2. Continue:
///       • Empty input          → silently complete; default icon stays.
///       • Digits / emoji       → inline "Letters only, please."; field
///                                 retains the input so the user can edit.
///       • Otherwise            → first whitespace-separated word stored
///                                 as `userName`; "Personalising your
///                                 app…" branded transition; system alert
///                                 for the icon switch lands inside that
///                                 transition; cover dismisses on success.
///   3. Cover dismisses; Library reveals with the personalised greeting.
struct OnboardingView: View {

    let onComplete: () -> Void

    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""
    @State private var inputText:  String = ""
    @State private var validationError: Bool = false
    @State private var isPersonalising: Bool = false
    @State private var personalisingLetter: Character = "i"
    @FocusState private var fieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewLetter: Character {
        let firstChar = inputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        return firstChar ?? "i"
    }

    var body: some View {
        ZStack {
            Color.inkBackgroundPrimary.ignoresSafeArea()

            if isPersonalising {
                PersonalisingTransition(letter: personalisingLetter)
                    .transition(.opacity)
            } else {
                onboardingForm
                    .transition(.opacity)
            }
        }
        .animation(.inkSpring(InkSpring.smooth), value: isPersonalising)
    }

    // MARK: Form

    private var onboardingForm: some View {
        VStack(spacing: Ink.Spacing.xl) {
            Spacer()

            // Live wordmark preview — the moment that sells personalisation.
            BrandWordmark(letter: previewLetter, size: 96)
                .inkAnimation(InkSpring.snappy, value: previewLetter)
                .frame(height: 120)
                .accessibilityLabel("Wordmark preview")

            VStack(spacing: Ink.Spacing.md) {
                Text("What should we call this?")
                    .font(.inkHeadline)
                    .foregroundColor(.inkTextPrimary)

                TextField("Your name", text: $inputText)
                    .font(.inkTitle2)
                    .foregroundColor(.inkTextPrimary)
                    .multilineTextAlignment(.center)
                    .focused($fieldFocused)
                    .submitLabel(.done)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.words)
                    .frame(maxWidth: 280)
                    .padding(.vertical, 12)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.inkBorderSubtle)
                            .frame(height: 1)
                    }
                    .onChange(of: inputText) { _, _ in
                        // Clear the validation error as soon as the user
                        // edits — re-running validation belongs to the
                        // Continue tap.
                        if validationError { validationError = false }
                    }
                    .onSubmit { commit() }

                // Reserved-height validation slot — empty by default so
                // the layout doesn't jump when the message appears.
                Text(validationError ? "Letters only, please." : " ")
                    .font(.inkCaption)
                    .foregroundColor(validationError ? .inkDestructive : .clear)
                    .frame(height: 18)
            }

            InkButton("Continue", style: .primary) { commit() }
                .frame(maxWidth: 280)

            Spacer()
        }
        .padding(.horizontal, Ink.Spacing.xl)
        .onAppear { fieldFocused = true }
    }

    // MARK: Commit

    private func commit() {
        switch validateName(inputText) {
        case .acceptEmpty:
            userName = ""
            // Empty input → no icon change, no transition. Just dismiss.
            onComplete()

        case .invalid:
            validationError = true
            HapticManager.shared.contextMenuOpened()  // light "nope" feedback
            // Field intact, cursor stays — `inputText` unchanged.

        case .accept(let firstWord):
            userName = firstWord
            personalisingLetter = firstWord.first ?? "i"
            // Show the personalising transition first so the user has
            // 800ms with their wordmark before the system icon-change
            // alert lands on top.
            isPersonalising = true
            let delay: TimeInterval = reduceMotion ? 0.0 : 0.8
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                updateAppIcon(for: firstWord)
                // setAlternateIconName presents an alert that the user
                // dismisses; once dismissed, finish onboarding. We don't
                // get a callback for "alert dismissed", but completion
                // fires once the icon switch resolves; in practice the
                // alert is up only briefly. Allow another short beat
                // before dismissing the cover so the wordmark stays put
                // until the user reads the alert.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    onComplete()
                }
            }
        }
    }
}

// MARK: - Personalising transition

/// "Personalising your app…" full-bleed screen that frames the system
/// icon-change alert. The wordmark animates a single subtle pulse on
/// the dot so the user sees the brand form before the alert lands.
private struct PersonalisingTransition: View {
    let letter: Character
    @State private var pulse: CGFloat = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Ink.Spacing.xl) {
            Spacer()
            BrandWordmark(letter: letter, size: 120)
                .scaleEffect(pulse, anchor: .bottomTrailing)
            Text("Personalising your app…")
                .font(.inkHeadline)
                .foregroundColor(.inkTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(UIColor(hex: BrandIconRenderer.backgroundHex)))
        .ignoresSafeArea()
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.6).repeatCount(1, autoreverses: true)) {
                pulse = 1.04
            }
        }
    }
}

// MARK: - Settings row

/// Settings → About → Your Name row. Same validation rules as onboarding,
/// smaller wordmark above the field, commits on submit / focus loss.
struct YourNameCard: View {
    @AppStorage(PersonalIdentity.nameKey) private var userName: String = ""
    @State private var buffer:           String = ""
    @State private var validationError: Bool   = false
    @FocusState private var focused:    Bool

    private var previewLetter: Character {
        let firstChar = buffer
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        return firstChar ?? "i"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            HStack(alignment: .center, spacing: Ink.Spacing.md) {
                BrandWordmark(letter: previewLetter, size: 36)
                    .inkAnimation(InkSpring.snappy, value: previewLetter)
                    .frame(width: 56, height: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Your Name")
                        .font(.inkBody)
                        .foregroundColor(.inkTextPrimary)
                    TextField("Add your name", text: $buffer)
                        .font(.inkSubhead)
                        .foregroundColor(.inkTextSecondary)
                        .focused($focused)
                        .submitLabel(.done)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.words)
                        .onSubmit { commit() }
                        .onChange(of: focused) { _, isFocused in
                            if !isFocused { commit() }
                        }
                        .onChange(of: buffer) { _, _ in
                            if validationError { validationError = false }
                        }
                }
            }
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.vertical, Ink.Spacing.sm)

            // Reserved-height row for either the validation error or
            // the helper subtitle. Toggling between them keeps the card
            // height stable.
            Group {
                if validationError {
                    Text("Letters only, please.")
                        .foregroundColor(.inkDestructive)
                } else {
                    Text("Personalises your app icon and home screen.")
                        .foregroundColor(.inkTextTertiary)
                }
            }
            .font(.inkCaption)
            .padding(.horizontal, Ink.Spacing.md)
            .padding(.bottom, Ink.Spacing.sm)
        }
        .onAppear { buffer = userName }
    }

    private func commit() {
        switch validateName(buffer) {
        case .acceptEmpty:
            // Empty + commit = clear name. Reverts to default icon.
            userName = ""
            updateAppIcon(for: "")
        case .invalid:
            validationError = true
            HapticManager.shared.contextMenuOpened()
        case .accept(let firstWord):
            userName = firstWord
            buffer   = firstWord    // reflect normalisation
            updateAppIcon(for: firstWord)
        }
    }
}

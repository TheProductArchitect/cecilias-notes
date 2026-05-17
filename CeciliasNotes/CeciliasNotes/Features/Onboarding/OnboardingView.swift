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
    // `c` is the brand's default letter — matches the bundle's
    // primary AppIcon (the `c·` mark Cecilia's Notes ships with).
    @State private var personalisingLetter: Character = "c"
    @FocusState private var fieldFocused: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var previewLetter: Character {
        let firstChar = inputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        return firstChar ?? "c"
    }

    /// True when there is at least one non-whitespace character. The
    /// onboarding flow now requires a name — Continue is disabled
    /// until this is true, so empty submissions can't escape the
    /// cover. Whitespace-only input also reads as empty.
    private var isValidInput: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: isPersonalising)
    }

    // MARK: Form

    private var onboardingForm: some View {
        VStack(spacing: CeciliasNotes.Spacing.xl) {
            Spacer()

            // Live wordmark preview — the moment that sells personalisation.
            BrandWordmark(letter: previewLetter, size: 96)
                .ceciliasNotesAnimation(CeciliasNotesSpring.snappy, value: previewLetter)
                .frame(height: 120)
                .accessibilityLabel("Wordmark preview")

            VStack(spacing: CeciliasNotes.Spacing.md) {
                Text("What should we call this?")
                    .font(.ceciliasNotesHeadline)
                    .foregroundColor(.inkTextPrimary)

                TextField("Your name", text: $inputText)
                    .font(.ceciliasNotesTitle2)
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
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(validationError ? .inkDestructive : .clear)
                    .frame(height: 18)
            }

            // Continue is disabled until the user types a non-empty
            // name. `.disabled` suppresses the tap (no haptic, no
            // press animation), and the 0.4 opacity mirrors the spec's
            // visual disabled state.
            CeciliasNotesButton("Continue", style: .primary) { commit() }
                .frame(maxWidth: 280)
                .disabled(!isValidInput)
                .opacity(isValidInput ? 1 : 0.4)
                .animation(.ceciliasNotesSpring(CeciliasNotesSpring.fade), value: isValidInput)

            Spacer()
        }
        .padding(.horizontal, CeciliasNotes.Spacing.xl)
        .onAppear { fieldFocused = true }
    }

    // MARK: Commit

    private func commit() {
        // The Continue button is disabled when input is empty, so we
        // shouldn't reach `commit()` with whitespace-only text — but
        // guard anyway in case `.onSubmit` fires from the keyboard.
        guard isValidInput else { return }

        switch validateName(inputText) {
        case .invalid:
            validationError = true
            HapticManager.shared.contextMenuOpened()  // light "nope" feedback
            // Field intact, cursor stays — `inputText` unchanged.

        case .accept(let firstWord):
            userName = firstWord
            // Mirror to the App Group so the widget extension renders
            // the user's possessive on the home screen, not the
            // brand fallback "cecilia's notes·".
            PersonalIdentity.mirrorNameToAppGroup(firstWord)
            // Persist completion **immediately** so the user is never
            // shown onboarding again, even if they kill the app during
            // the 1.4s personalising transition + icon-switch alert.
            // The cover's visual dismissal is driven by a separate
            // @State in LibraryView via `onComplete`, not by the
            // persisted flag — so writing the flag here doesn't
            // dismiss the cover prematurely.
            persistOnboardingCompleted()

            personalisingLetter = firstWord.first ?? "c"
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

    /// Mark the onboarding flow as complete in UserDefaults. The cover's
    /// visual dismissal is independent (driven by `onComplete`), so this
    /// only commits to the persistent store.
    private func persistOnboardingCompleted() {
        UserDefaults.standard.set(
            true,
            forKey: PersonalIdentity.onboardingCompletedKey
        )
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
        VStack(spacing: CeciliasNotes.Spacing.xl) {
            Spacer()
            BrandWordmark(letter: letter, size: 120)
                .scaleEffect(pulse, anchor: .bottomTrailing)
            Text("Personalising your app…")
                .font(.ceciliasNotesHeadline)
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
                        .foregroundColor(.inkTextPrimary)
                    TextField("Add your name", text: $buffer)
                        .font(.ceciliasNotesSubhead)
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
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.vertical, CeciliasNotes.Spacing.sm)

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
            .font(.ceciliasNotesCaption)
            .padding(.horizontal, CeciliasNotes.Spacing.md)
            .padding(.bottom, CeciliasNotes.Spacing.sm)
        }
        .onAppear { buffer = userName }
    }

    private func commit() {
        // Settings → About explicitly allows the user to *clear* their
        // name (graceful fallback to "cecilia's." in the splash and a
        // blank masthead). The shared validator now treats empty as
        // `.invalid` to keep onboarding strict, so we handle the clear
        // path here before delegating.
        let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            // No-op if already cleared — focus-loss fires on every
            // field interaction and would otherwise re-mirror + reload
            // widget timelines on each defocus.
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
            // Skip the side-effects (icon + App Group mirror + widget
            // timeline reload) when the committed value matches what's
            // already stored. Without this guard, every focus-loss on
            // the Settings field re-mirrors and reloads timelines.
            guard firstWord != userName else {
                buffer = firstWord    // still normalise display
                return
            }
            userName = firstWord
            buffer   = firstWord    // reflect normalisation
            updateAppIcon(for: firstWord)
            PersonalIdentity.mirrorNameToAppGroup(firstWord)
        }
    }
}

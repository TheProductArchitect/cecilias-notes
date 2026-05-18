import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Storage keys

enum PersonalIdentity {
    static let nameKey               = "app.user.name"
    static let onboardingCompletedKey = "app.onboarding.completed"

    /// One-shot UserDefaults key holding the user's name when an icon
    /// update is queued from a UI state that can't safely host the
    /// system icon-change alert (e.g. mid-onboarding-dismiss transition).
    /// Picked up by `applyPendingIconUpdateIfNeeded()` from a settled
    /// view's `onAppear` — see the Step 0.75 Phase G iOS 26 timing fix
    /// in `updateAppIcon(for:)`.
    static let pendingIconUpdateKey = "personalIdentity.pendingIconUpdate"

    /// App Group key the widget extension reads to render the
    /// possessive in the brand wordmark. Must be kept in sync with
    /// `nameKey` — every commit path that touches `nameKey` should
    /// call `mirrorNameToAppGroup()` so the widget never lags the
    /// app's identity.
    static let appGroupNameKey = "user.displayName"
    private static let appGroupSuite = "group.com.wave.venu.Ink"

    /// Mirror the canonical user name into the App Group's shared
    /// `UserDefaults` so the widget extension can read it. Falls
    /// back to `nameKey` from `UserDefaults.standard` when no
    /// explicit value is supplied — useful from app-launch hooks
    /// that just want to make sure the App Group is in sync with
    /// whatever the user previously committed. No-ops cleanly in
    /// dev builds without the App Group entitlement.
    static func mirrorNameToAppGroup(_ name: String? = nil) {
        let resolved = name ?? UserDefaults.standard.string(forKey: nameKey) ?? ""
        let suite    = UserDefaults(suiteName: appGroupSuite)
        // Defensive guard — no-op when the value hasn't changed. This
        // makes the function safe to call from any stray site without
        // risking a write loop. `RootView.init` used to call it on
        // every re-evaluation, and even though that call has been
        // removed, the guard means any *future* accidental caller
        // can't relight the same fuse. Skips the UserDefaults write
        // AND the WidgetCenter reload — both are pointless when the
        // stored value is already what we'd write.
        let existing = suite?.string(forKey: appGroupNameKey) ?? ""
        guard existing != resolved else { return }
        suite?.set(resolved, forKey: appGroupNameKey)
        #if DEBUG
        print("[PersonalIdentity] mirror → \(appGroupSuite)/\(appGroupNameKey) = \"\(resolved)\"")
        #endif
        // WidgetKit's natural refresh cadence is up to 15 minutes;
        // without an explicit reload the brand-mark possessive
        // (e.g. "cecilia's") lags every name change. `reloadAllTimelines`
        // tells the system to re-fetch every active widget's data
        // and re-render — the user sees the new name within
        // 2–3s on the home / lock screen.
        WidgetCenter.shared.reloadAllTimelines()
    }
}

// MARK: - Name validation

/// Outcome of validating a name TextField. Onboarding now requires a
/// name on first launch — the Continue button is disabled when input
/// is empty, so this validator is only invoked on non-empty input.
/// Empty input therefore falls through to `.invalid` (the defensive
/// choice if a future caller forgets the gate); callers that want a
/// "clear the name" path (Settings → About) should handle the
/// empty case themselves before calling.
enum NameValidationResult: Equatable {
    /// Valid input. The associated value is the stored name (first
    /// whitespace-separated word, original casing preserved).
    case accept(String)
    /// Empty input, or contains digits or emoji. Show
    /// "Letters only, please." inline for the latter.
    case invalid
}

/// Runs the validation rules from the spec.
///   • empty / whitespace               → invalid (callers must gate)
///   • any digit (U+0030…U+0039)        → invalid
///   • any extended-pictographic emoji   → invalid
///   • otherwise → accept(firstWord)
///
/// Apostrophes, hyphens, diacritics, non-Latin letters all pass through.
func validateName(_ input: String) -> NameValidationResult {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .invalid }

    for scalar in trimmed.unicodeScalars {
        // Digits.
        if scalar.value >= 0x30 && scalar.value <= 0x39 {
            return .invalid
        }
        // Emoji. `isEmojiPresentation` catches the typical pictographic
        // emoji (faces, hearts, etc.). Some letter-like scalars below
        // U+2600 confuse `isEmoji` alone, so we require the
        // *presentation* property as the disqualifier.
        if scalar.properties.isEmojiPresentation {
            return .invalid
        }
    }

    let firstWord = trimmed.split(whereSeparator: { $0.isWhitespace })
        .first
        .map(String.init) ?? ""
    if firstWord.isEmpty { return .invalid }
    return .accept(firstWord)
}

// MARK: - Icon variant mapping

/// Maps a name (or arbitrary first character) to one of the 26 alternate
/// icon keys (`a` … `z`), or `nil` if no Latin letter is reachable. Strips
/// diacritics so "Naïve" → "n", "Émile" → "e", "Ångström" → "a". Returns
/// `nil` for names that don't start with a Latin letter (Cyrillic,
/// Chinese, Arabic, etc.) — those keep the default app icon.
enum BrandIcon {
    static func variantKey(for firstCharacter: Character) -> String? {
        // Diacritic strip via folding; works for Latin-derived scripts
        // including Vietnamese, Polish, Czech, Turkish.
        let stripped = String(firstCharacter)
            .folding(options: .diacriticInsensitive, locale: .current)
        guard let asciiChar = stripped.lowercased().first,
              asciiChar.isLetter,
              asciiChar.isASCII
        else { return nil }
        return String(asciiChar)
    }

    /// Convenience wrapper: takes the user's full name (possibly empty),
    /// returns the key — or nil if no valid letter is reachable.
    static func variantKey(forName name: String) -> String? {
        guard let firstChar = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .first
        else { return nil }
        return variantKey(for: firstChar)
    }
}

// MARK: - Greeting

/// Possessive grammar for the Library home greeting.
///   • Empty name → empty string (Library shows nothing in that slot).
///   • Name ending in "s" (case-insensitive) → "name' notes" (Chris' notes).
///   • Otherwise → "name's notes" (alex's notes).
/// Entire string is lowercased — matches the wordmark convention.
func libraryGreeting(forName name: String) -> String {
    guard !name.isEmpty else { return "" }
    let lower  = name.lowercased()
    let suffix = lower.hasSuffix("s") ? "'" : "'s"
    return "\(lower)\(suffix) notes"
}

// MARK: - Icon switching
//
// Known issue (Step 0.75 Phase G, deferred to post-Step-0.75):
// On iOS 26, `UIApplication.setAlternateIconName(_:)` invoked anywhere
// near onboarding completion returns `NSPOSIXErrorDomain` code 35
// (EAGAIN, "Resource temporarily unavailable") from the system's
// internal `LSIconAlertManager`. The icon silently doesn't change.
// Pre-iOS-26 builds (verified against the byte-identical pre-rename-v5
// code path) worked reliably; iOS 26 tightened the presentation-context
// requirements for the mandatory "You have changed the icon for…"
// alert that Apple does not allow apps to suppress.
//
// We tried three mitigations in commits 3a7ba5a / a7b6140 / 16aeb92:
//   1. Bug-fixed ThemeManager passing the wrong icon key (real bug, kept).
//   2. Deferred the call from onboarding completion to LibraryView.onAppear
//      so the scene would be "settled." Didn't help — keyboard teardown
//      from onboarding is still in flight when LibraryView appears, and
//      LSIconAlertManager still rejects the presentation context.
//   3. EAGAIN-aware retry loop (5 attempts, 0–4s backoff). Didn't help
//      either — every retry hit the same condition. Reverted in Phase G;
//      no point keeping noise without payoff.
//
// An A/B test on a throwaway branch isolated the trigger but not a
// usable fix: removing the `.environment(\.theme, ...)` and
// `.preferredColorScheme(_:)` modifiers from `CeciliasNotesApp`'s
// WindowGroup (added in Phase B `27d057b`) likely lets the call land,
// but those modifiers are load-bearing for the entire theme system and
// cannot be removed without rewriting Phase B.
//
// Practical impact in 1.0: muted. The primary AppIcon now ships as the
// "C." letterform (commit 16aeb92), so users whose name starts with C
// see the correct icon by accident even when the swap silently fails.
// Other users see a "C." icon when they'd see their initial. The
// in-app wordmark personalisation (BrandWordmark) is unaffected — it
// reads the user's name directly and renders the correct letter.
//
// Post-1.0 paths to explore (in priority order):
//   • Move icon swap out of the onboarding flow entirely — surface it
//     as a "Personalise app icon" row in Settings, where the user
//     explicitly taps to change. Settings is a fully-settled scene
//     where LSIconAlertManager works reliably.
//   • Replace `.preferredColorScheme` with a less-aggressive trait
//     propagation mechanism that doesn't keep the scene in a
//     SwiftUI-managed trait-transitioning state.
//   • File feedback with Apple. EAGAIN with no retry-success-window is
//     a regression from documented behavior.

/// Queue a switch to the alternate icon keyed by the user's name's first
/// letter. Writes the user's name to `pendingIconUpdateKey`; the actual
/// `setAlternateIconName(_:)` call happens from
/// `applyPendingIconUpdateIfNeeded()` invoked from `LibraryView.onAppear`.
/// See the file header above for the iOS 26 LSIconAlertManager known issue.
@MainActor
func updateAppIcon(for name: String) {
    guard UIApplication.shared.supportsAlternateIcons else { return }
    UserDefaults.standard.set(name, forKey: PersonalIdentity.pendingIconUpdateKey)
}

/// Apply any icon update queued by `updateAppIcon(for:)`. Safe to call
/// from any settled view's `onAppear` — no-ops if no update is pending.
/// Clears the pending flag unconditionally so a silent EAGAIN failure
/// doesn't trigger a retry on every subsequent library appearance.
@MainActor
func applyPendingIconUpdateIfNeeded() {
    let defaults = UserDefaults.standard
    guard let pendingName = defaults.string(forKey: PersonalIdentity.pendingIconUpdateKey) else { return }
    defaults.removeObject(forKey: PersonalIdentity.pendingIconUpdateKey)
    let app = UIApplication.shared
    guard app.supportsAlternateIcons else { return }
    let key = BrandIcon.variantKey(forName: pendingName)
    if app.alternateIconName == key { return }
    app.setAlternateIconName(key) { error in
        if let error = error {
            #if DEBUG
            print("[BrandIcon] setAlternateIconName(\(key ?? "nil")) failed: \(error)")
            #endif
        }
    }
}

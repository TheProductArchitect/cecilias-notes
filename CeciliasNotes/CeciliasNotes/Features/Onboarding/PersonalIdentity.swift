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

/// Queue a switch to the alternate icon keyed by the user's name's first
/// letter. The actual `setAlternateIconName(_:)` call is deferred to the
/// first settled view (`LibraryView.onAppear` → `applyPendingIconUpdateIfNeeded()`)
/// rather than firing from the onboarding completion handler directly.
///
/// **Why deferred:** on iOS 26 the system's `LSIconAlertManager` (which
/// presents the mandatory "You have changed the icon for…" alert that
/// Apple does not allow apps to suppress) fails to acquire its
/// presentation token while the onboarding window is still mid-dismiss,
/// returning `NSPOSIXErrorDomain Code 35 ("Resource temporarily
/// unavailable")`. The call silently does nothing. Pre-iOS-26 the
/// transition timing was looser and the call landed during the transition.
/// Routing through `pendingIconUpdateKey` + `LibraryView.onAppear` gives
/// the alert manager a settled scene to work with.
@MainActor
func updateAppIcon(for name: String) {
    let app = UIApplication.shared
    // Diagnostic logging (Step 0.75 Phase G regression diagnosis). Unconditional
    // so the iPad device console surfaces it without a debug build attach.
    // Remove once on-device verification confirms the deferred call lands.
    print("[BrandIcon][diag] updateAppIcon(for: \"\(name)\") called — queuing pending update")
    print("[BrandIcon][diag] supportsAlternateIcons = \(app.supportsAlternateIcons)")
    guard app.supportsAlternateIcons else { return }
    let key = BrandIcon.variantKey(forName: name)
    print("[BrandIcon][diag] resolved key = \(key ?? "nil"), currentAlternate = \(app.alternateIconName ?? "nil")")
    UserDefaults.standard.set(name, forKey: PersonalIdentity.pendingIconUpdateKey)
    print("[BrandIcon][diag] wrote pendingIconUpdate = \"\(name)\" — will fire from LibraryView.onAppear")
}

/// Apply any icon update queued by `updateAppIcon(for:)`. Safe to call
/// from any settled view's `onAppear` — no-ops if no update is pending.
/// Clears the pending flag UNCONDITIONALLY (success OR failure) so a
/// presentation failure doesn't trigger a retry on every subsequent
/// library appearance.
@MainActor
func applyPendingIconUpdateIfNeeded() {
    let defaults = UserDefaults.standard
    guard let pendingName = defaults.string(forKey: PersonalIdentity.pendingIconUpdateKey) else { return }
    defaults.removeObject(forKey: PersonalIdentity.pendingIconUpdateKey)
    print("[BrandIcon][diag] applyPendingIconUpdateIfNeeded — pendingName = \"\(pendingName)\"")
    let app = UIApplication.shared
    guard app.supportsAlternateIcons else { return }
    let key = BrandIcon.variantKey(forName: pendingName)
    print("[BrandIcon][diag] resolved key = \(key ?? "nil"), currentAlternate = \(app.alternateIconName ?? "nil")")
    if app.alternateIconName == key {
        print("[BrandIcon][diag] no-op: already at \(key ?? "nil")")
        return
    }
    app.setAlternateIconName(key) { error in
        if let error = error {
            print("[BrandIcon][diag] setAlternateIconName(\(key ?? "nil")) FAILED: \(error)")
        } else {
            print("[BrandIcon][diag] setAlternateIconName(\(key ?? "nil")) SUCCESS")
        }
    }
}

import Foundation
import SwiftUI
import UIKit
import WidgetKit

// MARK: - Storage keys

enum PersonalIdentity {
    static let nameKey               = "app.user.name"
    static let onboardingCompletedKey = "app.onboarding.completed"

    /// App Group key the widget extension reads to render the
    /// possessive in the brand wordmark. Must be kept in sync with
    /// `nameKey` — every commit path that touches `nameKey` should
    /// call `mirrorNameToAppGroup()` so the widget never lags the
    /// app's identity.
    static let appGroupNameKey = "user.displayName"
    private static let appGroupSuite = "group.app.ceciliasnotes"

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
// The app icon mirrors the first letter of the user's name — one
// bundled alternate icon per letter; the primary is the "C."
// letterform.
//
// iOS 26 issue: `UIApplication.setAlternateIconName(_:)` can fail
// with `NSPOSIXErrorDomain` 35 (EAGAIN) when invoked during scene
// churn — notably right after onboarding, while the keyboard is
// dismissing and the trait environment is still transitioning —
// because the system can't present its mandatory "you changed the
// icon for…" alert (which apps cannot suppress).
//
// Design — `reconcileAppIcon()` is idempotent and self-healing:
//   • It derives the desired icon from the stored user name and, if
//     the live `alternateIconName` doesn't match, runs a gated swap.
//     Nothing is consumed — a failed attempt simply leaves the
//     mismatch in place for the next reconcile to retry.
//   • It runs from `LibraryView.onAppear` (every launch and every
//     return to the library) and on theme apply, so a swap that
//     loses the iOS 26 race during onboarding lands automatically on
//     a later, settled pass — no user action, no Settings toggle.
//   • `IconUpdateGate` still holds each attempt until the scene is
//     foreground-active and the keyboard dismissed; the in-session
//     retry covers residual `LSIconAlertManager` contention.
//
// This replaces an earlier one-shot `pendingIconUpdateKey` scheme
// that removed its pending flag *before* attempting the swap — so a
// single EAGAIN failure stranded the icon permanently with no retry
// path. The mandatory system alert still appears whenever a swap
// finally succeeds.

/// True while a reconcile swap is queued in the gate or its retry
/// chain is running — prevents overlapping attempts (and duplicate
/// system alerts) when several call sites reconcile at once.
@MainActor private var iconReconcileInFlight = false

/// Reconcile the app icon toward the user's name. Idempotent and
/// self-healing: no-ops when the icon already matches, and a failed
/// attempt leaves the mismatch for the next call to retry. Safe to
/// call from any settled view's `onAppear` and on theme change.
///
/// `preferredName` lets a caller that's mid-write (onboarding
/// completion) pass the name explicitly; otherwise the stored
/// `nameKey` value is the source of truth.
@MainActor
func reconcileAppIcon(preferredName: String? = nil) {
    let app = UIApplication.shared
    guard app.supportsAlternateIcons else { return }

    let name = preferredName
        ?? UserDefaults.standard.string(forKey: PersonalIdentity.nameKey)
        ?? ""
    let desiredKey = BrandIcon.variantKey(forName: name)
    guard app.alternateIconName != desiredKey else { return }
    guard !iconReconcileInFlight else {
        print("[BrandIcon][diag] reconcile — swap already in flight, skipping")
        return
    }

    iconReconcileInFlight = true
    print("[BrandIcon][diag] reconcile — current=\(app.alternateIconName ?? "primary") "
        + "desired=\(desiredKey ?? "primary") — handing to gate")
    IconUpdateGate.shared.whenReady {
        setAlternateIconWithRetry(desiredKey, attemptsLeft: 3)
    }
}

/// Onboarding entry point. The name is already being written to
/// `nameKey` by the onboarding flow; this forwards to
/// `reconcileAppIcon`, passing the name explicitly in case that
/// write hasn't landed yet.
@MainActor
func updateAppIcon(for name: String) {
    reconcileAppIcon(preferredName: name)
}

/// Gated swap with a short in-session retry. `IconUpdateGate` has
/// already held this until the scene/keyboard are settled; the
/// 1s-spaced retries cover residual `LSIconAlertManager` contention.
/// On exhaustion the in-flight flag is cleared so the next
/// `reconcileAppIcon()` — next library appearance or launch —
/// retries automatically.
@MainActor
private func setAlternateIconWithRetry(_ key: String?, attemptsLeft: Int) {
    let app = UIApplication.shared
    print("[BrandIcon][diag] setAlternateIconName(\(key ?? "nil")) — attempt (\(attemptsLeft) left)")
    app.setAlternateIconName(key) { error in
        // `setAlternateIconName`'s completion is not guaranteed on
        // the main thread — hop back before touching UIKit/state.
        Task { @MainActor in
            if let error {
                print("[BrandIcon][diag] setAlternateIconName(\(key ?? "nil")) FAILED: \(error)")
                if attemptsLeft > 1 {
                    try? await Task.sleep(for: .seconds(1))
                    setAlternateIconWithRetry(key, attemptsLeft: attemptsLeft - 1)
                } else {
                    // Give up for this session — `reconcileAppIcon()`
                    // retries on the next library appearance.
                    iconReconcileInFlight = false
                }
            } else {
                print("[BrandIcon][diag] setAlternateIconName(\(key ?? "nil")) SUCCESS")
                iconReconcileInFlight = false
            }
        }
    }
}

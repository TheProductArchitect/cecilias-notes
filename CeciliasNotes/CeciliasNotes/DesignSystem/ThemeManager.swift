import SwiftUI
import Combine
import UIKit

// MARK: - ThemeManager

/// Owner of the user's theme selection. Reads/writes to App Group
/// UserDefaults so the widget extension sees the same value the main app
/// sees (the widget itself still follows system appearance in 1.0 per
/// architecture §17; this just keeps the door open).
///
/// Migration from the previous "ink.theme" key (which stored "light" /
/// "dark") runs once on first launch of this build: "light" maps to
/// "default", "dark" maps to "midnight", any other value falls back to
/// "default". The old key is left intact so a rollback to the previous
/// build doesn't lose the user's pre-Step-0.75 choice.
@MainActor
public final class ThemeManager: ObservableObject {

    /// Shared instance used by app-root injection and anywhere that
    /// needs the current theme without an environment lookup (e.g.
    /// non-SwiftUI code).
    public static let shared = ThemeManager()

    /// Published so SwiftUI views observing the manager re-render on
    /// theme change. Most views should read `@Environment(\.theme)`
    /// instead — the manager's injection at app root keeps the
    /// environment in sync.
    @Published public private(set) var current: Theme

    private let defaults: UserDefaults
    private static let currentIdKey = "theme.currentId"
    private static let legacyKey    = "ink.theme"
    private static let appGroupSuite = "group.com.wave.venu.Ink"

    // MARK: Init

    public init() {
        // App Group defaults — falls back to standard if the suite isn't
        // available (e.g. tests, previews without entitlements).
        self.defaults = UserDefaults(suiteName: Self.appGroupSuite) ?? .standard
        self.current = Self.loadInitialTheme(from: defaults)
    }

    // MARK: Public API

    public func setTheme(_ theme: Theme) {
        guard theme.id != current.id else { return }
        current = theme
        defaults.set(theme.id, forKey: Self.currentIdKey)
        updateAppIcon()
        NotificationCenter.default.post(name: .themeDidChange, object: theme)
    }

    // MARK: Initial load + migration

    private static func loadInitialTheme(from defaults: UserDefaults) -> Theme {
        // 1. Honour an explicit Step 0.75 choice if one exists.
        if let id = defaults.string(forKey: currentIdKey),
           let match = Theme.all.first(where: { $0.id == id }) {
            return match
        }

        // 2. One-time migration from the legacy "ink.theme" key. Map
        //    "light" → "default", "dark" → "midnight"; anything else
        //    falls through to the default. The legacy key is left
        //    intact so a rollback to the previous build still sees it.
        if let legacy = defaults.string(forKey: legacyKey) {
            let migrated: Theme = {
                switch legacy {
                case "dark":  return .midnight
                case "light": return .default
                default:      return .default
                }
            }()
            defaults.set(migrated.id, forKey: currentIdKey)
            return migrated
        }

        // 3. No prior choice — first launch.
        return .default
    }

    // MARK: App icon

    /// Swaps the home-screen app icon to match the user's name initial.
    /// Per-theme icon variants are deferred (Flag #6, Phase A2) — in 1.0
    /// only the existing per-letter icons exist, so theme swaps DO NOT
    /// change the icon palette, only the letter. Wiring the asset name
    /// composition here so that when Midnight icon variants ship later
    /// the swap point is already correct.
    private func updateAppIcon() {
        // TODO (post-1.0): When Midnight icon variants ship, compose
        // `\(current.appIconAssetPrefix)-\(letter)` instead. For now,
        // keep using the existing per-letter family so we don't try
        // to set a non-existent icon name and trigger a console error.
        guard let letter = currentUserInitial() else {
            UIApplication.shared.setAlternateIconName(nil) { error in
                if let error = error {
                    print("[Theme] Reset to primary icon failed: \(error)")
                }
            }
            return
        }
        let iconName = "Icon-\(letter)"
        UIApplication.shared.setAlternateIconName(iconName) { error in
            if let error = error {
                print("[Theme] App icon swap failed: \(error)")
            }
        }
    }

    /// Lowercase initial of the user's name, or nil if none set. Mirrors
    /// the existing per-letter app-icon convention (Resources/AppIcons/
    /// Icon-a.png … Icon-z.png).
    private func currentUserInitial() -> String? {
        let name = defaults.string(forKey: PersonalIdentity.nameKey)
            ?? UserDefaults.standard.string(forKey: PersonalIdentity.nameKey)
            ?? ""
        guard let first = name.first else { return nil }
        let lowered = String(first).lowercased()
        // Only a–z map to icons; anything else (digits, accented chars
        // we don't have an asset for) falls back to the primary icon.
        return ("a"..."z").contains(lowered) ? lowered : nil
    }
}

// MARK: - Notification

public extension Notification.Name {
    /// Posted whenever `ThemeManager.setTheme(_:)` lands a new theme.
    /// `object` is the newly-current `Theme`.
    static let themeDidChange = Notification.Name("themeDidChange")
}

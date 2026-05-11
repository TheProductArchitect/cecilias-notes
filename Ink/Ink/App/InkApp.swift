import Combine
import CoreSpotlight
import SwiftData
import SwiftUI

@main
struct InkApp: App {
    @StateObject private var themeManager   = ThemeManager()
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync      = CloudSyncManager()
    @StateObject private var deepLink       = DeepLinkRouter()

    // Auto-open-last-notebook was removed: navigation state is
    // never persisted across cold launches per the architecture
    // rule. The legacy `ink.resume.enabled` /
    // `ink.resume.lastNotebookId` keys may still exist in
    // existing installs but are no longer read or written.

    init() {
        // Register Apple Intelligence's master toggle as ON-by-default
        // *without* persisting the value. `UserDefaults.register`
        // installs a fallback that's returned when the key is absent
        // from the user's domain — every read of
        // `intelligence.enabled` on a fresh install gets `true`, but
        // nothing is written to disk until the user explicitly
        // toggles it in Settings → Intelligence. Once they do, that
        // choice is permanent: register doesn't shadow a written
        // value, and we never overwrite `intelligence.enabled`
        // programmatically anywhere else. Net result on iOS 26
        // devices with Apple Intelligence: summaries / suggestions /
        // Ask My Notes are live on first launch with zero setup.
        UserDefaults.standard.register(defaults: [
            "intelligence.enabled": true,
        ])

        // Disable UIScrollView's default 150ms gesture-arbitration delay
        // so buttons inside scroll views (Settings cards, library search
        // results, etc.) fire on the first tap rather than the second.
        // The trade-off is the rare scenario where a user starts to
        // scroll from a button and the press registers first — for the
        // settings UIs and most app patterns this is the right trade.
        // Drawing canvas's UIScrollView already sets this directly.
        UIScrollView.appearance().delaysContentTouches = false

        // UI-test launch hook: when XCUIApplication launches us with the
        // "-uiTesting" argument, blow away every persisted ink.* /
        // app.user / app.onboarding key so each UI test starts from a
        // clean state. We do *not* delete the SwiftData store here —
        // that lives on disk and the tests that need a clean library
        // build it inline. Resume is also force-disabled so a UI test
        // run never lands inside an editor it didn't open itself.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            Self.resetForUITesting()
        }
    }

    /// Wipe persisted state for UI tests. Visible to test infra via the
    /// "-uiTesting" launch argument, and (in DEBUG) to engineering tools.
    /// Runs in `InkApp.init` BEFORE the StorageService singleton resolves
    /// its container, so we can also remove the on-disk SwiftData store
    /// — otherwise notebooks from a prior test run collide with elements
    /// the next test queries by label.
    static func resetForUITesting() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys
            where key.hasPrefix("ink.")
               || key.hasPrefix("app.user")
               || key.hasPrefix("app.onboarding") {
            defaults.removeObject(forKey: key)
        }
        // Force resume off for UI tests so a stale lastNotebookId
        // doesn't interfere even on the first launch after install.
        defaults.set(false, forKey: "ink.resume.enabled")

        // Wipe the on-disk SwiftData store. We attempt to remove the
        // entire `Ink` Application Support directory: it contains the
        // SQLite store and per-notebook resources (audio, media). This
        // runs before `StorageService.shared` resolves, so the next
        // container open creates a fresh empty DB.
        let inkDir = StorageService.inkDirectoryURL
        try? FileManager.default.removeItem(at: inkDir)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(themeManager)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(deepLink)
                // Inject the same `ModelContainer` the StorageService
                // owns so SwiftUI `@Query` views (sidebar's per-subject
                // count, future Phase 2 grid pagination) read from the
                // exact same store the manual `StorageService` API
                // writes to. Without this, `@Query` finds no container
                // in the environment and crashes.
                .modelContainer(storageService.container)
                .onAppear {
                    themeManager.applyTheme()
                    // Session-scoped values that should not survive a relaunch:
                    // - pixel-eraser size (resets to the user's Settings default
                    //   each time the app cold-starts).
                    UserDefaults.standard.removeObject(forKey: "ink.eraser.pixelSize.session")

                    // One-time defensive recompute of `totalPageCount`
                    // for any pre-existing notebooks whose denormalised
                    // count drifted from the live page list. Gated by a
                    // UserDefaults flag — subsequent launches no-op.
                    storageService.runOneTimePageCountBackfillIfNeeded()

                    // No navigation state restoration on cold launch
                    // — the app always lands in the library. The
                    // previous auto-open-last-notebook behaviour
                    // violated the "navigation state is never
                    // persisted across cold launches" rule and
                    // surprised users who closed the app from
                    // inside a notebook expecting to land home.
                    // Recents are still surfaced in the library
                    // grid via `RecentNotebooksTracker` — display
                    // only, no navigation side effect.
                }
                // Spotlight launch
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = SpotlightService.notebookId(fromIdentifier: id) {
                        deepLink.openNotebookId = uuid
                    }
                }
                // ink:// deep links
                .onOpenURL { url in
                    deepLink.handle(url)
                }
        }
        .commands { InkCommands(deepLink: deepLink) }
    }

}

// MARK: - DeepLinkRouter

/// Single source of truth for deep-link target. Views observe and react.
@MainActor
final class DeepLinkRouter: ObservableObject {

    /// When set, the Library should open this notebook in the editor.
    @Published var openNotebookId: UUID?

    /// When true (and `openNotebookId` is also set), the editor should present
    /// the export sheet immediately on appear.
    @Published var pendingExport: Bool = false

    /// When true, the Library should present the settings sheet.
    @Published var openSettings: Bool = false

    /// When true, the Library should immediately create a new playful-named
    /// notebook and open it in the editor — the Quick Capture flow.
    /// Set on cold launch (via the launch URL), checked once by `LibraryView`.
    @Published var pendingQuickCapture: Bool = false

    /// Parses `ink://open/{uuid}`, `ink://library`, `ink://settings`,
    /// `ink://quick-capture`.
    func handle(_ url: URL) {
        guard url.scheme == "ink" else { return }
        switch url.host {
        case "open":
            let raw = url.lastPathComponent
            if let uuid = UUID(uuidString: raw) {
                openNotebookId = uuid
            }
        case "settings":
            openSettings = true
        case "library":
            openNotebookId = nil
            openSettings   = false
        case "quick-capture":
            pendingQuickCapture = true
        default:
            break
        }
    }
}

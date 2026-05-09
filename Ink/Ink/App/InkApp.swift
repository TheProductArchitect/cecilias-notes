import Combine
import CoreSpotlight
import SwiftUI

@main
struct InkApp: App {
    @StateObject private var themeManager   = ThemeManager()
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync      = CloudSyncManager()
    @StateObject private var deepLink       = DeepLinkRouter()

    /// Default ON. Settings → Resume Where You Left Off toggles this.
    @AppStorage("ink.resume.enabled") private var resumeEnabled: Bool = true
    @AppStorage("ink.resume.lastNotebookId") private var lastNotebookIdString: String = ""

    init() {
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
                .onAppear {
                    themeManager.applyTheme()
                    // Session-scoped values that should not survive a relaunch:
                    // - pixel-eraser size (resets to the user's Settings default
                    //   each time the app cold-starts).
                    UserDefaults.standard.removeObject(forKey: "ink.eraser.pixelSize.session")

                    // Defer the resume check by one runloop tick so a
                    // cold-launch `ink://quick-capture` URL has time to
                    // land in `.onOpenURL` and set `pendingQuickCapture`
                    // before we'd otherwise reopen the last notebook.
                    DispatchQueue.main.async {
                        if !deepLink.pendingQuickCapture {
                            restoreLastSession()
                        }
                    }
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

    /// On cold launch, route to the last-opened notebook if the user opted in
    /// and the notebook still exists. Stale ids are cleared without warning.
    private func restoreLastSession() {
        guard resumeEnabled,
              !lastNotebookIdString.isEmpty,
              let uuid = UUID(uuidString: lastNotebookIdString)
        else { return }

        if StorageService.shared.fetchAllNotebooks().contains(where: { $0.id == uuid }) {
            deepLink.openNotebookId = uuid
        } else {
            // Notebook was deleted between sessions — clean up.
            lastNotebookIdString = ""
            UserDefaults.standard.removeObject(forKey: "ink.resume.lastPageIndex")
        }
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

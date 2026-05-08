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

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(themeManager)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(deepLink)
                .onAppear {
                    themeManager.applyTheme()
                    restoreLastSession()
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

    /// Parses `ink://open/{uuid}`, `ink://library`, `ink://settings`.
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
        default:
            break
        }
    }
}

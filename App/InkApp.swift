import CoreSpotlight
import SwiftUI

@main
struct InkApp: App {
    @StateObject private var themeManager   = ThemeManager()
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync      = CloudSyncManager()
    @StateObject private var deepLink       = DeepLinkRouter()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(themeManager)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(deepLink)
                .onAppear { themeManager.applyTheme() }
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

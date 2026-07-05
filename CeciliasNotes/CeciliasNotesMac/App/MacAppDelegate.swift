import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {

    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Route the `⌘,` command through `NSApp.sendAction` for the
        // `Settings…` menu item — SwiftUI's `Settings { }` scene
        // registers this selector at launch; posting it here means
        // any part of the app can programmatically open Settings
        // via `NotificationCenter.default.post(name: .macOpenSettings, ...)`
        // (Debug menu, keyboard shortcut, error banner "open Settings"
        // link — the door stays open in one place).
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .macOpenSettings,
            object: nil,
            queue: .main
        ) { _ in
            if #available(macOS 14, *) {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } else {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        }
    }

    deinit {
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == MacHandoff.activityType,
              let notebookIdString = userActivity.userInfo?[MacHandoff.notebookIdKey] as? String,
              let notebookId = UUID(uuidString: notebookIdString),
              let pageIdString = userActivity.userInfo?[MacHandoff.pageIdKey] as? String,
              let pageId = UUID(uuidString: pageIdString)
        else { return false }

        NotificationCenter.default.post(
            name: .macOpenHandoffPage,
            object: nil,
            userInfo: [
                MacHandoff.notebookIdKey: notebookId,
                MacHandoff.pageIdKey: pageId,
                MacHandoff.scrollOffsetKey: userActivity.userInfo?[MacHandoff.scrollOffsetKey] as? CGFloat ?? 0,
                MacHandoff.zoomKey: userActivity.userInfo?[MacHandoff.zoomKey] as? CGFloat ?? 1,
            ]
        )
        return true
    }
}

extension Notification.Name {
    static let macOpenHandoffPage = Notification.Name("app.ceciliasnotes.mac.handoff")
}

enum MacHandoff {
    static let activityType = "app.ceciliasnotes.page"
    static let notebookIdKey = "notebookId"
    static let pageIdKey = "pageId"
    static let scrollOffsetKey = "scrollOffset"
    static let zoomKey = "zoom"
}

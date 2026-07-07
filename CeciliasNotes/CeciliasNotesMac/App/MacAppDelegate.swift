import AppKit

final class MacAppDelegate: NSObject, NSApplicationDelegate {

    private var settingsObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        MainThreadWatchdog.install()
        #endif
        MacQuickCaptureController.shared.install()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        startMultipeerBackgroundReconnectIfNeeded()
        Task { @MainActor in reconcileAppIcon() }
        // Unlike iOS (which resets on every backgrounding), the Mac's
        // only other reset point is applicationWillTerminate — which a
        // crash or power loss never reaches. Without this, two abnormal
        // shutdowns days apart (with healthy sessions in between) would
        // wrongly trip the CloudKit dirty-launch auto-fallback. Surviving
        // launch by 60s means the container came up fine.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            UserDefaults.standard.set(0, forKey: "ceciliasnotes.swiftdata.dirtyLaunchStreak")
            // A healthy CloudKit launch also re-arms the library's
            // "sync paused" banner — a dismissal should silence the
            // current incident, not all future ones.
            if CloudKitContainerState.status == .privateDatabase {
                UserDefaults.standard.set(false, forKey: "ceciliasnotes.mac.icloudBannerDismissed")
            }
        }
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
            // Observer is registered with `queue: .main`, so this
            // closure always runs on the main actor.
            MainActor.assumeIsolated {
                if #available(macOS 14, *) {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } else {
                    NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.set(0, forKey: "ceciliasnotes.swiftdata.dirtyLaunchStreak")
    }

    private func startMultipeerBackgroundReconnectIfNeeded() {
        Task { @MainActor in
            let hasPairedPeers = !MultipeerPairingStore.pairedPeerNames().isEmpty
            let receiveEnabled = UserDefaults.standard.bool(forKey: "ceciliasnotes.multipeer.enabled")
            if hasPairedPeers || receiveEnabled {
                MultipeerSendService.shared.startBackgroundReconnect()
            }
        }
    }

    deinit {
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "ceciliasnotes" {
            NotificationCenter.default.post(
                name: .macIncomingDeepLinkURL,
                object: nil,
                userInfo: ["url": url]
            )
        }
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == PageHandoff.activityType,
              let payload = PageHandoff.parse(userActivity.userInfo)
        else { return false }

        NotificationCenter.default.post(
            name: .macOpenHandoffPage,
            object: nil,
            userInfo: [
                PageHandoff.notebookIdKey: payload.notebookId,
                PageHandoff.pageIdKey: payload.pageId,
                PageHandoff.scrollOffsetKey: payload.scrollOffset,
                PageHandoff.zoomKey: payload.zoom,
            ]
        )
        return true
    }
}

extension MacAppDelegate {
    @objc func newNoteFromSelection(
        _ pboard: NSPasteboard,
        userData: String,
        error: NSErrorPointer
    ) {
        guard let text = pboard.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return }
        Task { @MainActor in
            MacServicesImport.createNote(from: text)
        }
    }
}

extension Notification.Name {
    static let macOpenHandoffPage = Notification.Name("app.ceciliasnotes.mac.handoff")
    /// Widget / external `ceciliasnotes://` opens delivered via `NSApplicationDelegate`.
    static let macIncomingDeepLinkURL = Notification.Name("app.ceciliasnotes.mac.incomingDeepLinkURL")
}

import SwiftData
import SwiftUI

@main
struct CeciliasNotesMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync = CloudSyncManager()
    @StateObject private var themeManager = ThemeManager()
    @State private var showOnboarding = !UserDefaults.standard.bool(forKey: "app.onboarding.completed")

    init() {
        // Start MultipeerSyncService at app init so the Mac begins
        // advertising / browsing the `_cn-sync._tcp` service the
        // moment the app launches (matching the iPad behaviour in
        // `CeciliasNotesApp.swift`). No-op when the user hasn't
        // opted in from Settings → cloud; safe to reference the
        // singleton unconditionally because construction is cheap
        // and idempotent. Requires the network.client +
        // network.server entitlements and the `NSBonjourServices`
        // Info.plist declaration that live alongside this target.
        _ = MultipeerSyncService.shared
    }

    var body: some Scene {
        WindowGroup {
            MacRootView(showOnboarding: $showOnboarding)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.current)
                .preferredColorScheme(
                    themeManager.current.interfaceStyle == .dark ? .dark : .light
                )
                .modelContainer(storageService.container)
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .commands {
            MacAppCommands()
        }

        Settings {
            MacSettingsView()
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.current)
        }
    }
}

import SwiftData
import SwiftUI

@main
struct CeciliasNotesMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync = CloudSyncManager()
    @StateObject private var themeManager = ThemeManager()
    @StateObject private var deepLink = DeepLinkRouter()
    @StateObject private var libraryVM = LibraryViewModel()
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
                .background(MacWindowTag(identifier: "library-main"))
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(themeManager)
                .environmentObject(deepLink)
                .environmentObject(libraryVM)
                .environment(\.theme, themeManager.current)
                .preferredColorScheme(
                    themeManager.current.interfaceStyle == .dark ? .dark : .light
                )
                .modelContainer(storageService.container)
                .frame(minWidth: 960, minHeight: 640)
                .background(MacSettingsBridge())
                .onOpenURL { url in
                    NSApp.activate(ignoringOtherApps: true)
                    deepLink.handle(url)
                }
        }
        .windowStyle(.titleBar)
        .commands {
            MacAppCommands()
        }

        WindowGroup(id: "notebook-editor", for: UUID.self) { $notebookID in
            if let notebookID {
                MacNotebookEditorWindow(notebookID: notebookID)
                    .environmentObject(libraryVM)
                    .environmentObject(storageService)
                    .environmentObject(cloudSync)
                    .environmentObject(themeManager)
                    .environmentObject(deepLink)
                    .environment(\.theme, themeManager.current)
                    .preferredColorScheme(
                        themeManager.current.interfaceStyle == .dark ? .dark : .light
                    )
                    .modelContainer(storageService.container)
                    .background(MacSettingsBridge())
            }
        }
        .defaultSize(width: 960, height: 700)

        Settings {
            MacSettingsView()
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(themeManager)
                .environment(\.theme, themeManager.current)
        }
    }
}

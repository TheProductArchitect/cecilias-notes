import SwiftUI

/// Routes `.macOpenSettings` notifications to SwiftUI's Settings scene.
/// More reliable than `NSApp.sendAction(showSettingsWindow:)` from buttons.
struct MacSettingsBridge: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onReceive(NotificationCenter.default.publisher(for: .macOpenSettings)) { _ in
                openSettings()
            }
    }
}

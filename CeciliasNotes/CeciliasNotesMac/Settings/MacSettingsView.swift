import SwiftUI

struct MacSettingsView: View {
    @AppStorage("ceciliasnotes.swiftdata.cloudkitDisabled") private var cloudKitDisabled = false
    @AppStorage("mac.editor.zoomStep") private var zoomStep = 0.1
    @AppStorage("mac.export.defaultFormat") private var defaultExportFormat = MacExportFormat.pdf.rawValue
    @AppStorage("app.onboarding.completed") private var onboardingCompleted = false
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            Form {
                Picker("Theme", selection: themeBinding) {
                    ForEach(Theme.all) { choice in
                        Text(choice.displayName).tag(choice.id)
                    }
                }
                Toggle("Show onboarding again", isOn: Binding(
                    get: { !onboardingCompleted },
                    set: { onboardingCompleted = !$0 }
                ))
            }
            .tabItem { Label("Appearance", systemImage: "paintbrush") }

            Form {
                LabeledContent("iCloud sync", value: cloudSyncStatusLabel)
                Toggle("Disable database sync (advanced)", isOn: $cloudKitDisabled)
                Text("Media files sync via iCloud Drive separately from SwiftData.")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundMuted)
            }
            .tabItem { Label("iCloud", systemImage: "icloud") }

            Form {
                Slider(value: $zoomStep, in: 0.05...0.25, step: 0.05) {
                    Text("Zoom step")
                }
                Text("Current step: \(Int(zoomStep * 100))%")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundMuted)
            }
            .tabItem { Label("Editor", systemImage: "pencil.and.outline") }

            Form {
                Picker("Default export format", selection: $defaultExportFormat) {
                    ForEach(MacExportFormat.allCases, id: \.rawValue) { format in
                        Text(format.label).tag(format.rawValue)
                    }
                }
            }
            .tabItem { Label("Export", systemImage: "square.and.arrow.up") }

            Form {
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                LabeledContent("Bundle ID", value: Bundle.main.bundleIdentifier ?? "—")
            }
            .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480, height: 340)
    }

    private var themeBinding: Binding<String> {
        Binding(
            get: { themeManager.current.id },
            set: { id in
                if let match = Theme.all.first(where: { $0.id == id }) {
                    themeManager.setTheme(match)
                }
            }
        )
    }

    private var cloudSyncStatusLabel: String {
        switch cloudSync.syncStatus {
        case .disabled: return "Disabled"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .syncing: return "Syncing…"
        case .waitingForNetwork: return "Waiting for network"
        case .error(let message): return message
        }
    }
}

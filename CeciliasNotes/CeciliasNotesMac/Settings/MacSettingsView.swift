import SwiftUI

/// macOS Settings window — editorial tabs matching the iPad settings rail.
struct MacSettingsView: View {
    @AppStorage("ceciliasnotes.swiftdata.cloudkitDisabled") private var cloudKitDisabled = false
    @AppStorage("ceciliasnotes.resume.enabled") private var resumeEnabled = true
    @AppStorage("ceciliasnotes.transcription.quality") private var transcriptionQuality = TranscriptionQuality.accurate.rawValue
    @AppStorage("ceciliasnotes.audio.saveClips") private var saveAudioClips = true
    @AppStorage("ceciliasnotes.transcription.auto") private var autoTranscribe = true
    @AppStorage("ceciliasnotes.quiz.enabled") private var quizEnabled = true
    @AppStorage("intelligence.enabled") private var intelligenceEnabled = true
    @AppStorage("mac.editor.zoomStep") private var zoomStep = 0.1
    @AppStorage("mac.export.defaultFormat") private var defaultExportFormat = MacExportFormat.pdf.rawValue
    @AppStorage(MacCaptureHotkey.storageKey) private var captureHotkey = MacCaptureHotkey.optionCommandSpace.rawValue
    @State private var isStyleGuidePresented = false
    @EnvironmentObject private var storageService: StorageService
    @EnvironmentObject private var cloudSync: CloudSyncManager
    @EnvironmentObject private var themeManager: ThemeManager
    @Environment(\.theme) private var theme

    var body: some View {
        TabView {
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
            audioTab
                .tabItem { Label("Audio", systemImage: "waveform") }
            cloudTab
                .tabItem { Label("iCloud", systemImage: "icloud") }
            intelligenceTab
                .tabItem { Label("Intelligence", systemImage: "sparkles") }
            editorTab
                .tabItem { Label("Editor", systemImage: "pencil.and.outline") }
            exportTab
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
            captureTab
                .tabItem { Label("Capture", systemImage: "square.and.pencil") }
            storageTab
                .tabItem { Label("Storage", systemImage: "internaldrive") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
#if DEBUG
            debugTab
                .tabItem { Label("Debug", systemImage: "ladybug") }
#endif
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(minWidth: 520, minHeight: 420)
#if DEBUG
        .sheet(isPresented: $isStyleGuidePresented) {
            MacStyleGuideSheet()
                .environment(\.theme, theme)
                .frame(minWidth: 480, minHeight: 360)
        }
#endif
    }

    private var appearanceTab: some View {
        Form {
            Picker("Theme", selection: themeBinding) {
                ForEach(Theme.all) { choice in
                    Text(choice.displayName).tag(choice.id)
                }
            }
            Toggle("Resume where you left off", isOn: $resumeEnabled)
            Button("Show onboarding again") {
                UserDefaults.standard.set(false, forKey: PersonalIdentity.onboardingCompletedKey)
                NotificationCenter.default.post(name: .macShowOnboarding, object: nil)
            }
        }
        .formStyle(.grouped)
    }

    private var audioTab: some View {
        Form {
            Picker("Transcription quality", selection: $transcriptionQuality) {
                ForEach(TranscriptionQuality.allCases, id: \.rawValue) { quality in
                    Text(quality.displayName).tag(quality.rawValue)
                }
            }
            Toggle("Save audio clips after recording", isOn: $saveAudioClips)
            Toggle("Auto-transcribe recordings", isOn: $autoTranscribe)
            Button("Open System Settings → Privacy") {
                PlatformApp.openSystemSettings()
            }
        }
        .formStyle(.grouped)
    }

    private var cloudTab: some View {
        MacCloudSettingsView()
            .environmentObject(cloudSync)
            .environment(\.theme, theme)
    }

    private var intelligenceTab: some View {
        Form {
            Toggle("Apple Intelligence features", isOn: $intelligenceEnabled)
            Toggle("Quiz generation", isOn: $quizEnabled)
            if IntelligenceService.shared.canRun {
                Text("Apple Intelligence is available on this Mac.")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundMuted)
            } else {
                Text("Quiz generation uses the Mac MCP helper when Apple Intelligence is unavailable.")
                    .font(.caption)
                    .foregroundStyle(theme.foregroundMuted)
            }
        }
        .formStyle(.grouped)
    }

    private var editorTab: some View {
        Form {
            Slider(value: $zoomStep, in: 0.05...0.25, step: 0.05) {
                Text("Zoom step")
            }
            Text("Current step: \(Int(zoomStep * 100))%")
                .font(.caption)
                .foregroundStyle(theme.foregroundMuted)
            Text("Handwriting stays on iPad — Mac is for typing, review, and export.")
                .font(.caption)
                .foregroundStyle(theme.foregroundMuted)
        }
        .formStyle(.grouped)
    }

    private var exportTab: some View {
        Form {
            Picker("Default export format", selection: $defaultExportFormat) {
                ForEach(MacExportFormat.allCases, id: \.rawValue) { format in
                    Text(format.label).tag(format.rawValue)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var captureTab: some View {
        Form {
            Picker("Global quick capture", selection: $captureHotkey) {
                ForEach(MacCaptureHotkey.allCases) { hotkey in
                    Text(hotkey.label).tag(hotkey.rawValue)
                }
            }
            .onChange(of: captureHotkey) { _, _ in
                NotificationCenter.default.post(name: .macCaptureHotkeyChanged, object: nil)
            }
            Text("Works system-wide when Cecilia's Notes is running. Menu-bar icon always opens capture.")
                .font(.caption)
                .foregroundStyle(theme.foregroundMuted)
        }
        .formStyle(.grouped)
    }

    private var storageTab: some View {
        MacStorageSettingsView()
    }

    private var shortcutsTab: some View {
        MacKeyboardShortcutsView()
    }

#if DEBUG
    private var debugTab: some View {
        MacDebugSettingsView()
    }
#endif

    private var aboutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("cecilia's notes")
                        .font(.system(size: 17, weight: .heavy))
                    Text(appVersion.lowercased())
                        .font(.system(size: 9))
                        .foregroundStyle(theme.recessiveQuaternary)
                }
                YourNameCard()
#if DEBUG
                Button("Open style guide") { isStyleGuidePresented = true }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.accent)
#endif
                Text("no backend. no accounts. all data stays on your device.")
                    .font(.system(size: 11).italic())
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
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

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }
}

import Combine
import Foundation
import Speech
import StoreKit
import SwiftUI

// MARK: - Persisted enums

/// Mirror of `PencilDoubleTapAction` (in Editor/Tools/InkTool.swift) — must use the
/// same raw values so the @AppStorage key `ink.pencil.doubletap` round-trips
/// between Settings (writer) and EditorViewModel (reader).
enum DoubleTapAction: String, CaseIterable {
    case switchTool       = "switchTool"
    case toggleEraser     = "toggleEraser"
    case showColorPicker  = "showColorPicker"
    case doNothing        = "doNothing"

    var displayName: String {
        switch self {
        case .switchTool:      return "Switch tool"
        case .toggleEraser:    return "Toggle eraser"
        case .showColorPicker: return "Show colours"
        case .doNothing:       return "Nothing"
        }
    }
}

/// Persisted purely for backward-compatibility of users' UserDefaults values;
/// no UI exposes this and no drawing code consumes it.
/// TODO: re-expose when custom stroke renderer ships (audit #40).
enum PressureSetting: String, CaseIterable {
    case soft   = "soft"
    case medium = "medium"
    case firm   = "firm"

    var displayName: String { rawValue.capitalized }
}

enum TranscriptionQuality: String, CaseIterable {
    case fast     = "fast"
    case accurate = "accurate"

    var displayName: String { rawValue.capitalized }
}

// MARK: - SettingsSection

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance  = "Appearance"
    case pencil      = "Apple Pencil"
    case newPages    = "New Pages"
    case audio       = "Audio & Transcription"
    case cloud       = "iCloud"
    case storage     = "Storage"
    case about       = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance: return "paintpalette"
        case .pencil:     return "applepencil"
        case .newPages:   return "doc.badge.plus"
        case .audio:      return "waveform"
        case .cloud:      return "icloud"
        case .storage:    return "internaldrive"
        case .about:      return "info.circle"
        }
    }
}

// MARK: - SettingsViewModel

@MainActor
final class SettingsViewModel: ObservableObject {

    /// Explicit ObservableObject publisher. Required under Swift 5.10's stricter
    /// @MainActor isolation: the compiler refuses to synthesise conformance for
    /// a @MainActor class whose only @Published-equivalent properties are
    /// @AppStorage-wrapped enums. Declaring it explicitly satisfies the protocol.
    /// Settings views observe individual @AppStorage projected bindings
    /// (`$viewModel.someProp`) which publish independently via UserDefaults.
    let objectWillChange = ObservableObjectPublisher()

    let themeManager:     ThemeManager
    let cloudSyncManager: CloudSyncManager

    // MARK: Pencil
    @AppStorage("ink.pencil.doubletap")   var doubleTapAction:  DoubleTapAction  = .switchTool
    @AppStorage("ink.pencil.hoverPreview") var hoverPreviewEnabled: Bool         = true
    @AppStorage("ink.haptics.drawing")    var drawingHapticsEnabled: Bool        = true

    // The two below are persisted but not surfaced or read by drawing code.
    // Kept so existing users' values aren't orphaned if the settings return.
    // TODO: re-expose when custom stroke renderer ships (audit #39, #40).
    @AppStorage("ink.pencil.pressure")    var pressureSetting:  PressureSetting  = .medium
    @AppStorage("ink.pencil.smoothing")   private var _strokeSmoothing: Double   = 50

    /// Default OFF — Pencil draws, finger scrolls/zooms. When ON, finger can also draw.
    @AppStorage("ink.canvas.fingerDrawingEnabled") var fingerDrawingEnabled: Bool = false

    /// Default Pixel Eraser size (used when no per-tool override is in effect).
    @AppStorage("ink.eraser.pixelSize") var pixelEraserSize: Double = 24

    // MARK: General

    /// "Resume Where You Left Off" — when ON, cold launch reopens the last
    /// notebook at the last viewed page. Default ON.
    @AppStorage("ink.resume.enabled") var resumeEnabled: Bool = true

    // MARK: New Pages
    @AppStorage("ink.newpage.size")    var defaultPageSize: PageSize = .a4
    @AppStorage("ink.newpage.autoAdd") var autoAddPage: Bool = true
    @AppStorage("ink.newpage.template") private var _defaultTemplateRaw: String = "blank"

    var defaultTemplate: PageTemplate {
        get {
            (try? JSONDecoder().decode(PageTemplate.self,
                from: _defaultTemplateRaw.data(using: .utf8) ?? Data())) ?? .blank
        }
        set {
            _defaultTemplateRaw = (try? String(
                data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "blank"
        }
    }

    // MARK: Audio
    @AppStorage("ink.transcription.locale")  var transcriptionLocale: String = ""
    @AppStorage("ink.transcription.auto")    var autoTranscribe: Bool = true
    @AppStorage("ink.transcription.quality") var transcriptionQuality: TranscriptionQuality = .fast

    // MARK: Storage metrics
    @Published var storageInfo: StorageInfo?       = nil
    @Published var exportedPDFsBytes: Int64        = 0
    @Published var audioAnnotationCount: Int       = 0
    @Published var isLoadingStorage: Bool          = false

    // MARK: About
    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "Version \(v) (Build \(b))"
    }

    var supportsHoverPreview: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    // MARK: Init

    init(themeManager: ThemeManager, cloudSyncManager: CloudSyncManager) {
        self.themeManager     = themeManager
        self.cloudSyncManager = cloudSyncManager

        // The previous version installed a UserDefaults.didChangeNotification
        // observer that called objectWillChange.send() so views reading
        // `viewModel.fooSetting` directly would refresh. It turned out to be
        // a likely source of "Publishing changes from within view updates"
        // warnings — UserDefaults fires on every @AppStorage default-write
        // at app launch, which is inside SwiftUI's first body pass.
        //
        // Removed. Views must use the @AppStorage projected binding
        // (`$viewModel.fooSetting`) for SwiftUI controls. Plain reads
        // (`viewModel.fooSetting == .x`) won't auto-refresh — but @AppStorage
        // already publishes its own changes through its property wrapper,
        // and SwiftUI subscribes to those at the view level, not via the
        // surrounding ObservableObject.
    }

    // MARK: Storage

    func loadStorageMetrics() async {
        guard !isLoadingStorage else { return }
        isLoadingStorage = true
        storageInfo      = await StorageService.shared.localStorageUsed()
        exportedPDFsBytes = StorageService.shared.exportedPDFsSizeBytes()
        isLoadingStorage = false
    }

    func clearExportedPDFs() async throws {
        try await StorageService.shared.clearExportedPDFs()
        exportedPDFsBytes = 0
        storageInfo = await StorageService.shared.localStorageUsed()
    }

    func clearAudioRecordings() async throws {
        try await StorageService.shared.clearAudioRecordings()
        storageInfo = await StorageService.shared.localStorageUsed()
    }

    // MARK: Rate app

    func requestReviewIfEligible() {
        let key = "ink.review.requestedVersion"
        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        guard StorageService.shared.notebookCount() >= 3,
              UserDefaults.standard.string(forKey: key) != currentVersion
        else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        SKStoreReviewController.requestReview(in: scene)
        UserDefaults.standard.set(currentVersion, forKey: key)
    }

    // MARK: On-device transcription locales

    func supportedOnDeviceLocales() -> [Locale] {
        SFSpeechRecognizer.supportedLocales()
            .filter { locale in
                SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true
            }
            .sorted { a, b in
                let aName = Locale.current.localizedString(forIdentifier: a.identifier) ?? a.identifier
                let bName = Locale.current.localizedString(forIdentifier: b.identifier) ?? b.identifier
                return aName < bName
            }
    }
}

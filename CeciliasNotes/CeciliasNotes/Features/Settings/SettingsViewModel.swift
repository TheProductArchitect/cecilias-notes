import Combine
import Foundation
import Speech
import StoreKit
import SwiftUI

// MARK: - Persisted enums

/// Mirror of `PencilDoubleTapAction` (in Editor/Tools/CeciliasNotesTool.swift) — must use the
/// same raw values so the @AppStorage key `ceciliasnotes.pencil.doubletap` round-trips
/// between Settings (writer) and EditorViewModel (reader).
enum DoubleTapAction: String, CaseIterable {
    case switchTool       = "switchTool"
    case toggleEraser     = "toggleEraser"
    case showColorPicker  = "showColorPicker"
    case doNothing        = "doNothing"

    var displayName: String {
        switch self {
        case .switchTool:      return "switch tool"
        case .toggleEraser:    return "toggle eraser"
        case .showColorPicker: return "show colours"
        case .doNothing:       return "do nothing"
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
    case appearance   = "Appearance"
    case pencil       = "Apple Pencil"
    case audio        = "Audio & Transcription"
    case cloud        = "iCloud"
    case storage      = "Storage"
    case intelligence = "Intelligence"
    case about        = "About"
    #if DEBUG
    case debug        = "Debug"
    #endif

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appearance:   return "paintpalette"
        case .pencil:       return "applepencil"
        case .audio:        return "waveform"
        case .cloud:        return "icloud"
        case .storage:      return "internaldrive"
        case .intelligence: return "sparkles"
        case .about:        return "info.circle"
        #if DEBUG
        case .debug:        return "ladybug"
        #endif
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
    @AppStorage("ceciliasnotes.pencil.doubletap")   var doubleTapAction:  DoubleTapAction  = .switchTool
    @AppStorage("ceciliasnotes.pencil.hoverPreview") var hoverPreviewEnabled: Bool         = true
    @AppStorage("ceciliasnotes.haptics.drawing")    var drawingHapticsEnabled: Bool        = true

    // The two below are persisted but not surfaced or read by drawing code.
    // Kept so existing users' values aren't orphaned if the settings return.
    // TODO: re-expose when custom stroke renderer ships (audit #39, #40).
    @AppStorage("ceciliasnotes.pencil.pressure")    var pressureSetting:  PressureSetting  = .medium
    @AppStorage("ceciliasnotes.pencil.smoothing")   private var _strokeSmoothing: Double   = 50

    /// Default OFF — kept as a legacy backing store so existing
    /// installs' user choice survives the Step 3 mode rollout. New
    /// reads should go through `fingerDrawingMode` and resolve via
    /// `InputCapabilityDetector`.
    @AppStorage("ceciliasnotes.canvas.fingerDrawingEnabled") var fingerDrawingEnabled: Bool = false

    /// Step 3: user's resolution policy for finger drawing on the
    /// canvas. Defaults to `.auto` — finger-only iPads get finger
    /// drawing; iPads with a Pencil get pencilOnly. Resolved by
    /// callers via `mode.fingerDrawingEnabled(hasPencil:)` against
    /// `InputCapabilityDetector.shared.hasPencil`.
    @AppStorage("ceciliasnotes.canvas.fingerDrawingMode") var fingerDrawingMode: FingerDrawingMode = .auto

    // Pixel-eraser size setting removed — PencilKit's default
    // eraser behaviour now governs. The legacy
    // `ceciliasnotes.eraser.pixelSize` / `ceciliasnotes.eraser.pixelSize.session` keys
    // are no longer read; existing installs' stored values are
    // harmless leftovers.

    // MARK: - Pencil Pro squeeze (iOS 17.5+)

    /// User's choice for the Apple Pencil Pro squeeze gesture.
    /// Registered with a `"palette"` default in `CeciliasNotesApp.init`; the
    /// AppStorage default here is the same so a fresh field read
    /// without the register-defaults still resolves correctly.
    @AppStorage("pencil.squeeze.action") var squeezeAction: SqueezeAction = .palette

    /// The tool to switch to when `squeezeAction == .tool`.
    /// Defaults to `.eraser` per spec.
    @AppStorage("pencil.squeeze.tool") var squeezeTool: SqueezeToolChoice = .eraser

    // MARK: General

    /// "Resume Where You Left Off" — when ON, cold launch reopens the last
    /// notebook at the last viewed page. Default ON.
    @AppStorage("ceciliasnotes.resume.enabled") var resumeEnabled: Bool = true

    // The "New Pages" Settings section was removed. Auto-add and
    // page-template defaults are now per-notebook (`coverTone`,
    // `defaultTemplate`, `autoAddPagesOnScroll` on `Notebook`); the
    // legacy global keys (`ceciliasnotes.newpage.*`) are no longer read.

    // MARK: Audio
    @AppStorage("ceciliasnotes.transcription.locale")  var transcriptionLocale: String = ""
    /// Save the audio clip after recording. When OFF the recording is
    /// discarded once any transcript has been generated; if both this
    /// and `autoTranscribe` are OFF the recording is discarded
    /// outright. Default ON.
    @AppStorage("ceciliasnotes.audio.saveClips")       var saveAudioClips: Bool = true
    /// Run on-device speech recognition after recording. Default ON.
    /// Persists alongside `saveAudioClips`; the post-recording
    /// pipeline reads both at stop-time (toggle changes apply
    /// immediately).
    @AppStorage("ceciliasnotes.transcription.auto")    var autoTranscribe: Bool = true
    @AppStorage("ceciliasnotes.transcription.quality") var transcriptionQuality: TranscriptionQuality = .fast

    // MARK: Storage metrics
    @Published var storageInfo: StorageInfo?       = nil
    /// Wall-clock time of the most recent cache write that produced
    /// the value currently in `storageInfo`. The Storage view shows a
    /// "updated X min ago" suffix in `inkRecessiveTertiary` when this
    /// is older than `storageCacheStaleAfter`.
    @Published var storageInfoCachedAt: Date?      = nil
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

    /// UserDefaults key for the on-disk storage metrics cache.
    /// Stored as a JSON blob keyed `total / audio / media / db` plus
    /// an optional `cachedAt` timestamp so the Storage view can render
    /// a "updated X min ago" suffix when the cache is stale (the
    /// background warmup at app launch + a fresh `.task` recalculation
    /// on view appear keep this fresh in normal use).
    static let storageCacheKey     = "settings.storage.lastCalculated"
    static let storageCacheDateKey = "settings.storage.lastCalculatedDate"

    /// Age past which the cached storage value is considered stale and
    /// the Storage view shows an "updated X min ago" caption.
    static let storageCacheStaleAfter: TimeInterval = 5 * 60

    private struct StorageCacheEntry: Codable {
        let total: Int64
        let audio: Int64
        let media: Int64
        let db:    Int64
        // Optional for backwards-compatibility with caches written
        // before this field existed.
        var cachedAt: Date?
    }

    /// Reads the persisted storage metrics cache, if any. Used by
    /// both `SettingsViewModel.init` (to pre-populate `storageInfo`
    /// for instant first paint) and the `CeciliasNotesApp` background warmup
    /// (which checks whether a warm cache already exists so it can
    /// skip the recompute when the user hasn't been away long).
    static func readStorageCache() -> (info: StorageInfo, cachedAt: Date?)? {
        guard let raw    = UserDefaults.standard.data(forKey: storageCacheKey),
              let cached = try? JSONDecoder().decode(StorageCacheEntry.self, from: raw)
        else { return nil }
        return (
            StorageInfo(
                totalBytes: cached.total,
                audioBytes: cached.audio,
                mediaBytes: cached.media,
                dbBytes:    cached.db
            ),
            cached.cachedAt
        )
    }

    /// Persists the storage metrics cache. Safe to call from any
    /// thread — `UserDefaults` is its own concurrency boundary, and
    /// the JSON encoder is stateless. Called both from the foreground
    /// `loadStorageMetrics` path and the `CeciliasNotesApp` background warmup.
    static func persistStorageCache(_ info: StorageInfo, at date: Date = Date()) {
        let entry = StorageCacheEntry(
            total:    info.totalBytes,
            audio:    info.audioBytes,
            media:    info.mediaBytes,
            db:       info.dbBytes,
            cachedAt: date
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        UserDefaults.standard.set(data, forKey: storageCacheKey)
        UserDefaults.standard.set(date, forKey: storageCacheDateKey)
    }

    init(themeManager: ThemeManager, cloudSyncManager: CloudSyncManager) {
        self.themeManager     = themeManager
        self.cloudSyncManager = cloudSyncManager

        // Pre-populate `storageInfo` from the cache (if any) so the
        // first paint of Settings → Storage shows real numbers
        // instead of a placeholder. `loadStorageMetrics` still runs
        // on appear and overwrites with fresh values. The background
        // warmup in `CeciliasNotesApp` keeps the cache fresh even when the user
        // hasn't visited Settings recently.
        if let (info, cachedAt) = Self.readStorageCache() {
            self.storageInfo         = info
            self.storageInfoCachedAt = cachedAt
        }

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
        let fresh = await StorageService.shared.localStorageUsed()
        let now   = Date()
        storageInfo         = fresh
        storageInfoCachedAt = now
        exportedPDFsBytes   = StorageService.shared.exportedPDFsSizeBytes()
        isLoadingStorage    = false
        // Persist so the next entry into Settings → Storage shows
        // a stable value immediately. Cache write is best-effort —
        // worst case the user sees "calculating…" briefly on the
        // next launch.
        Self.persistStorageCache(fresh, at: now)
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
        let key = "ceciliasnotes.review.requestedVersion"
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

    // MARK: DEBUG synthetic data

    #if DEBUG
    /// Injects `count` synthetic notebooks into the store. DEBUG only —
    /// shipped builds don't surface the entry point. Runs on the
    /// `@MainActor` since `StorageService` is main-isolated.
    func generateSyntheticData(notebookCount: Int) async {
        try? StorageService.shared.generateSyntheticNotebooks(count: notebookCount)
    }

    /// Hard wipe of every notebook and subject. Destructive — meant
    /// for clearing synthetic data after a perf run.
    func wipeAllSyntheticData() async {
        try? StorageService.shared.wipeAllSyntheticData()
    }
    #endif

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

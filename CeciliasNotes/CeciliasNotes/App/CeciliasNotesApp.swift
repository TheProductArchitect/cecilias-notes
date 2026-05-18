import Combine
import CoreSpotlight
import SwiftData
import SwiftUI

@main
struct CeciliasNotesApp: App {
    /// UIApplicationDelegate-level crash-recovery + shutdown wiring.
    /// Phase 5D: the `app.shutdown.clean` flag now lives at this
    /// layer rather than the SwiftUI scenePhase observer. SwiftUI's
    /// `onChange(of: scenePhase)` can miss the `.background`
    /// transition if the system suspends the app while a sheet is
    /// transitioning; the UIKit `applicationDidEnterBackground` /
    /// `applicationWillTerminate` callbacks fire reliably across
    /// every shutdown path that the OS gives us a chance to observe.
    /// Force-quit + crash leave the gate at `false`, which is the
    /// signal the next launch reads to force-route to library home.
    @UIApplicationDelegateAdaptor(CeciliasNotesAppDelegate.self) private var appDelegate

    @StateObject private var themeManager   = ThemeManager()
    @StateObject private var storageService = StorageService.shared
    @StateObject private var cloudSync      = CloudSyncManager()
    @StateObject private var deepLink       = DeepLinkRouter()

    // Auto-open-last-notebook was removed: navigation state is
    // never persisted across cold launches per the architecture
    // rule. The legacy `ink.resume.enabled` /
    // `ink.resume.lastNotebookId` keys may still exist in
    // existing installs but are no longer read or written.

    init() {
        // Crash-recovery gate is established by `CeciliasNotesAppDelegate`
        // BEFORE SwiftUI instantiates this struct — see
        // `application(_:didFinishLaunchingWithOptions:)`. By the
        // time `init` runs, `LaunchRecovery.previousShutdownWasClean`
        // is already populated and the persisted flag has been
        // flipped to `false`.

        // Re-enable the hosting-hierarchy diagnostic swizzle. The
        // previous version filtered on parent-type and never matched;
        // this version only filters on the subview class containing
        // "ReparentingView", which is what the runtime warning is
        // actually about. DEBUG-only.
        #if DEBUG
        HostingHierarchyDiagnostics.installOnce()
        #endif

        // Register Apple Intelligence's master toggle as ON-by-default
        // *without* persisting the value. `UserDefaults.register`
        // installs a fallback that's returned when the key is absent
        // from the user's domain — every read of
        // `intelligence.enabled` on a fresh install gets `true`, but
        // nothing is written to disk until the user explicitly
        // toggles it in Settings → Intelligence. Once they do, that
        // choice is permanent: register doesn't shadow a written
        // value, and we never overwrite `intelligence.enabled`
        // programmatically anywhere else. Net result on iOS 26
        // devices with Apple Intelligence: summaries / suggestions /
        // Ask My Notes are live on first launch with zero setup.
        UserDefaults.standard.register(defaults: [
            "intelligence.enabled": true,
            // Pencil Pro squeeze defaults — "Show tool palette"
            // until the user picks a different action. The
            // `.tool` mode's selected tool defaults to `.eraser`
            // (matches the SettingsViewModel's @AppStorage
            // default), surfaced only when the user flips the
            // action to `.tool`.
            "pencil.squeeze.action": SqueezeAction.palette.rawValue,
            "pencil.squeeze.tool":   SqueezeToolChoice.eraser.rawValue,
        ])

        // Disable UIScrollView's default 150ms gesture-arbitration delay
        // so buttons inside scroll views (Settings cards, library search
        // results, etc.) fire on the first tap rather than the second.
        // The trade-off is the rare scenario where a user starts to
        // scroll from a button and the press registers first — for the
        // settings UIs and most app patterns this is the right trade.
        // Drawing canvas's UIScrollView already sets this directly.
        UIScrollView.appearance().delaysContentTouches = false

        // UI-test launch hook: when XCUIApplication launches us with the
        // "-uiTesting" argument, blow away every persisted ink.* /
        // app.user / app.onboarding key so each UI test starts from a
        // clean state. We do *not* delete the SwiftData store here —
        // that lives on disk and the tests that need a clean library
        // build it inline. Resume is also force-disabled so a UI test
        // run never lands inside an editor it didn't open itself.
        if ProcessInfo.processInfo.arguments.contains("-uiTesting") {
            Self.resetForUITesting()
        }
    }

    /// Wipe persisted state for UI tests. Visible to test infra via the
    /// "-uiTesting" launch argument, and (in DEBUG) to engineering tools.
    /// Runs in `CeciliasNotesApp.init` BEFORE the StorageService singleton resolves
    /// its container, so we can also remove the on-disk SwiftData store
    /// — otherwise notebooks from a prior test run collide with elements
    /// the next test queries by label.
    static func resetForUITesting() {
        let defaults = UserDefaults.standard
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys
            where key.hasPrefix("ink.")
               || key.hasPrefix("app.user")
               || key.hasPrefix("app.onboarding") {
            defaults.removeObject(forKey: key)
        }
        // Force resume off for UI tests so a stale lastNotebookId
        // doesn't interfere even on the first launch after install.
        defaults.set(false, forKey: "ink.resume.enabled")

        // Wipe the on-disk SwiftData store. We attempt to remove the
        // entire `Ink` Application Support directory: it contains the
        // SQLite store and per-notebook resources (audio, media). This
        // runs before `StorageService.shared` resolves, so the next
        // container open creates a fresh empty DB.
        let ceciliasNotesDir = StorageService.ceciliasNotesDirectoryURL
        try? FileManager.default.removeItem(at: ceciliasNotesDir)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .overlay(alignment: .top) {
                    // Step 6: persistent recording pill — visible
                    // across the whole app while a recording is in
                    // flight. Inside the editor, the prominent
                    // `FloatingRecordingControls` is the primary
                    // surface; this pill is the secondary "you're
                    // still recording" reminder for library /
                    // settings / modal sheets. Tap returns to the
                    // notebook where recording is happening.
                    RecordingPill()
                }
                .environmentObject(themeManager)
                .environmentObject(storageService)
                .environmentObject(cloudSync)
                .environmentObject(deepLink)
                // Step 0.75: inject the Theme value type via @Environment
                // so any view can read `@Environment(\.theme) var theme`.
                // Also drive `.preferredColorScheme(_:)` from the chosen
                // theme — that flips the trait collection, which makes
                // the existing dynamic-provider tokens in
                // CeciliasNotesColors.swift respond before Phase D
                // migrates them off the inkX namespace.
                .environment(\.theme, themeManager.current)
                .preferredColorScheme(
                    themeManager.current.interfaceStyle == .dark ? .dark : .light
                )
                // Inject the same `ModelContainer` the StorageService
                // owns so SwiftUI `@Query` views (sidebar's per-subject
                // count, future Phase 2 grid pagination) read from the
                // exact same store the manual `StorageService` API
                // writes to. Without this, `@Query` finds no container
                // in the environment and crashes.
                .modelContainer(storageService.container)
                .onAppear {
                    // Session-scoped values that should not survive a relaunch:
                    // - pixel-eraser size (resets to the user's Settings default
                    //   each time the app cold-starts).
                    // Pixel-eraser session key from the retired
                    // Settings slider — wiped at launch on the
                    // off-chance an old build left a value behind.
                    UserDefaults.standard.removeObject(forKey: "ink.eraser.pixelSize.session")
                    UserDefaults.standard.removeObject(forKey: "ink.eraser.pixelSize")

                    // One-time defensive recompute of `totalPageCount`
                    // for any pre-existing notebooks whose denormalised
                    // count drifted from the live page list. Gated by a
                    // UserDefaults flag — subsequent launches no-op.
                    storageService.runOneTimePageCountBackfillIfNeeded()

                    // MediaStorage migration v1: collapse the three
                    // legacy on-disk media layouts into the unified
                    // `Documents/MediaAttachments/{images,audio,lectures}/`
                    // tree. Idempotent — gated by a UserDefaults flag,
                    // subsequent launches only ensure the directory
                    // structure exists. See
                    // `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.B.
                    Task.detached(priority: .utility) {
                        await MediaStorage.migrateExistingFilesIfNeeded()
                    }

                    // Warm the storage-metrics cache on launch so the
                    // first time the user visits Settings → Storage
                    // the numbers are already there — no "calculating…"
                    // placeholder, even on a cold install. Runs at
                    // background priority off the main actor; the only
                    // shared writes are to `UserDefaults`, which has
                    // its own concurrency boundary.
                    Task.detached(priority: .background) {
                        let info = await StorageService.shared.localStorageUsed()
                        await MainActor.run {
                            SettingsViewModel.persistStorageCache(info)
                        }
                    }

                    // No navigation state restoration on cold launch
                    // — the app always lands in the library. The
                    // previous auto-open-last-notebook behaviour
                    // violated the "navigation state is never
                    // persisted across cold launches" rule and
                    // surprised users who closed the app from
                    // inside a notebook expecting to land home.
                    // Recents are still surfaced in the library
                    // grid via `RecentNotebooksTracker` — display
                    // only, no navigation side effect.
                }
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
        .commands { CeciliasNotesCommands(deepLink: deepLink) }
        // Phase 5D: shutdown-clean writes moved to
        // `CeciliasNotesAppDelegate.applicationDidEnterBackground` /
        // `applicationWillTerminate`. SwiftUI's scenePhase observer
        // can be racy under sheet transitions; the UIKit lifecycle
        // callbacks are the OS-guaranteed signals.
    }

}

// MARK: - LaunchRecovery

/// Cross-launch shutdown gate. Snapshotted in
/// `CeciliasNotesAppDelegate.application(_:didFinishLaunchingWithOptions:)`
/// from the `app.shutdown.clean` UserDefault. The delegate flips the
/// persisted value to `false` immediately; the delegate's
/// `applicationDidEnterBackground` / `applicationWillTerminate`
/// callbacks flip it back to `true` whenever iOS gives us a chance to
/// clean up. Net effect: a force-quit / OOM-kill / crash leaves the
/// persisted value at false, and the next launch's
/// `previousShutdownWasClean` snapshot reads `false`. Any view that
/// wants to gate restoration / splash-skip / auto-resume on a clean
/// previous shutdown reads this static.
enum LaunchRecovery {
    /// `true` when `app.shutdown.clean` was `true` at launch (or on
    /// the very first install where the key was absent and we
    /// optimistically default to `true`). `false` when the previous
    /// run terminated abnormally — see `RootView` for the
    /// restoration-suppression hookup.
    nonisolated(unsafe) static var previousShutdownWasClean: Bool = true
}

// MARK: - CeciliasNotesAppDelegate

/// `UIApplicationDelegate` shim that owns the crash-recovery gate.
/// Wired into `CeciliasNotesApp` via `@UIApplicationDelegateAdaptor`. Three
/// callbacks matter:
///
///   • `application(_:didFinishLaunchingWithOptions:)` — snapshots
///     the previous-run `app.shutdown.clean` value, flips it to
///     `false`, and (when the previous run was dirty) clears any
///     stale resume pointers so the next session can't restore into
///     a broken editor state. This runs BEFORE SwiftUI instantiates
///     `CeciliasNotesApp`, so `LaunchRecovery.previousShutdownWasClean` is
///     populated by the time the first `RootView` body evaluates.
///
///   • `applicationDidEnterBackground(_:)` — flips the flag to
///     `true`. iOS guarantees this fires before the system can
///     suspend / terminate the app under any normal path; missing it
///     means the next launch will treat the previous shutdown as
///     dirty and force the user to library home. This is the
///     critical write for the standard "user multitasks then
///     force-quits" sequence: background fires first, then the
///     user's force-quit produces no further lifecycle event.
///
///   • `applicationWillTerminate(_:)` — belt-and-braces redundancy
///     for the rare paths where iOS calls this directly (e.g.
///     low-memory termination of a foreground app). Not all
///     termination paths route through this method.
final class CeciliasNotesAppDelegate: NSObject, UIApplicationDelegate {

    private static let shutdownKey = "app.shutdown.clean"
    /// Phase 5A+5C Step 2: one-shot wipe gate. When this is absent
    /// from `UserDefaults` on launch, the V4 → V5 media-record stores
    /// are deleted (lectures first; audio + images added in later
    /// substeps). The gate is set after the wipe so subsequent
    /// launches no-op. There is intentionally no migration path —
    /// existing UserDefaults JSON records are discarded outright per
    /// the start-clean spec.
    private static let v5WipeKey = "schema.v5.wiped"
    /// Step 1 of the unified PageElement migration: one-shot wipe
    /// gate for the V5 → V6 schema bump. When this is absent from
    /// `UserDefaults` on launch, the V5 SwiftData store + the
    /// `Documents/MediaAttachments/` tree are deleted so the V6
    /// container opens onto a pristine library. Single-tester
    /// start-clean — no migration plan, agreed in the V6 scoping
    /// decision. The gate is set after the wipe so subsequent
    /// launches no-op.
    private static let v6WipeKey = "schema.v6.wiped"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions:
            [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let defaults = UserDefaults.standard
        let prevClean = defaults.object(forKey: Self.shutdownKey) as? Bool ?? true
        LaunchRecovery.previousShutdownWasClean = prevClean
        // Reset to false immediately so any subsequent crash leaves
        // the gate dirty for the next launch.
        defaults.set(false, forKey: Self.shutdownKey)
        if !prevClean {
            // Clear any stale per-notebook resume pointers so the
            // editor's "resume to last page" path can't restore into
            // the broken session that caused the unclean shutdown.
            defaults.removeObject(forKey: "ink.resume.lastNotebookId")
            defaults.removeObject(forKey: "ink.resume.lastPageIndex")
            #if DEBUG
            print("[Launch] previous shutdown was DIRTY — forcing library home + clearing resume keys")
            #endif
        }
        Self.runV5WipeIfNeeded(defaults: defaults)
        Self.runV6WipeIfNeeded(defaults: defaults)
        return true
    }

    /// One-shot wipe on the first V5 launch. Two parts:
    ///
    ///   1. Remove legacy UserDefaults JSON metadata stores so the
    ///      V5 SwiftData entities own those records exclusively.
    ///   2. Delete the V4 SwiftData store proactively. The audio
    ///      reshape (Step 3) drops `AudioAnnotation` columns; the
    ///      `ModelContainer` would hit the mismatch fallback at
    ///      `ceciliasNotesContainer()` and wipe anyway, but doing it here
    ///      avoids a noisy failed-open log on first launch.
    ///
    /// Files on disk under `Documents/MediaAttachments/` are left in
    /// place — they orphan silently and the user accepted that
    /// trade-off in the V5 scoping decision.
    ///
    /// Keys removed (added per substep):
    ///   • `lecture.store.v1` — Phase 5A+5C Step 2 (lectures).
    ///   • Future: `media.attachments.v1` (images).
    private static func runV5WipeIfNeeded(defaults: UserDefaults) {
        guard defaults.object(forKey: v5WipeKey) == nil else { return }

        // UserDefaults JSON stores (Phase 5A+5C Steps 2 + 4).
        defaults.removeObject(forKey: "lecture.store.v1")
        defaults.removeObject(forKey: "media.attachments.v1")

        // SwiftData store + WAL/SHM sidecars. Best-effort —
        // FileManager errors here are non-fatal because the
        // ModelContainer's own fallback path will recover.
        let storeURL = StorageService.ceciliasNotesDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-shm", "-wal", "-journal"] {
            try? FileManager.default.removeItem(
                at: storeURL.appendingPathExtension(String(suffix.dropFirst()))
            )
        }

        defaults.set(true, forKey: v5WipeKey)
        #if DEBUG
        print("[Launch] V5 wipe applied — UserDefaults media stores + V4 SwiftData store cleared")
        #endif
    }

    /// One-shot wipe on the first V6 launch. Three parts:
    ///
    ///   1. Delete the V5 SwiftData store + WAL/SHM sidecars. The
    ///      V6 schema adds `PageElement` and 7 content entities;
    ///      single-tester start-clean rather than writing a
    ///      migration plan.
    ///   2. Wipe `Documents/MediaAttachments/` (images, audio,
    ///      lectures, pdfs, pdf-previews). The V5 media files
    ///      reference rows that no longer exist; they orphan
    ///      otherwise and bloat iCloud Drive.
    ///   3. Drop the V5 resume pointers so the editor doesn't try
    ///      to restore into a notebook that no longer exists.
    ///
    /// Preserved: theme prefs (App Group UserDefaults), app
    /// settings, onboarding flags, per-notebook UUID-keyed stores
    /// (CoverToneStore, NotebookPreferencesStore, PDFBackingStore,
    /// etc.). Those last entries orphan harmlessly — their keys
    /// reference UUIDs that no longer exist in SwiftData, so
    /// nothing reads them. A future garbage-collection pass can
    /// sweep them when convenient.
    ///
    /// The CloudKit server-side copy stays intact; on first launch
    /// with the V6 container, CloudKit will start syncing the V6
    /// schema's empty model set up to the server, which (because
    /// V6 keeps all V5 entity types in its model list) drops no
    /// existing CloudKit records — they just won't be visible
    /// locally until the user re-adds them.
    ///
    /// Files on disk are best-effort — FileManager errors are
    /// non-fatal because the ModelContainer's own mismatch fallback
    /// will recover the SwiftData side regardless.
    private static func runV6WipeIfNeeded(defaults: UserDefaults) {
        guard defaults.object(forKey: v6WipeKey) == nil else { return }

        // 1. SwiftData store + sidecars.
        let storeURL = StorageService.ceciliasNotesDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-shm", "-wal", "-journal"] {
            try? FileManager.default.removeItem(
                at: storeURL.appendingPathExtension(String(suffix.dropFirst()))
            )
        }

        // 2. MediaAttachments tree (images, audio, lectures, pdfs).
        if let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first {
            let mediaRoot = docs.appendingPathComponent("MediaAttachments")
            try? FileManager.default.removeItem(at: mediaRoot)
        }

        // 3. Resume pointers referencing now-deleted notebooks.
        defaults.removeObject(forKey: "ink.resume.lastNotebookId")
        defaults.removeObject(forKey: "ink.resume.lastPageIndex")

        defaults.set(true, forKey: v6WipeKey)
        #if DEBUG
        print("[Launch] V6 wipe applied — V5 SwiftData store + Documents/MediaAttachments/ cleared")
        #endif
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        UserDefaults.standard.set(true, forKey: Self.shutdownKey)
        #if DEBUG
        print("[Launch] applicationDidEnterBackground → marked shutdown clean")
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        UserDefaults.standard.set(true, forKey: Self.shutdownKey)
        #if DEBUG
        print("[Launch] applicationWillTerminate → marked shutdown clean")
        #endif
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

    /// When true, the Library should immediately create a new playful-named
    /// notebook and open it in the editor — the Quick Capture flow.
    /// Set on cold launch (via the launch URL), checked once by `LibraryView`.
    @Published var pendingQuickCapture: Bool = false

    /// Parses `ink://open/{uuid}`, `ink://library`, `ink://settings`,
    /// `ink://quick-capture`.
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
        case "quick-capture":
            pendingQuickCapture = true
        default:
            break
        }
    }
}

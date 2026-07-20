import Combine
import CoreData
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

    /// One-shot gate so the launch-time notebook resume hook in
    /// `.onAppear` fires once per process. SwiftUI may evaluate
    /// `WindowGroup` content's `.onAppear` multiple times across
    /// rebuilds; re-firing the resume route on every appearance
    /// would re-open the editor cover the user just dismissed.
    @State private var didAttemptLaunchResume: Bool = false

    /// Foreground-return belt-and-suspenders for the alternate-icon
    /// swap. `LibraryView.onAppear` covers the normal "user returns
    /// to library" path, but if iOS suspends the app with the editor
    /// on screen the library never re-appears on the way back —
    /// this scenePhase hook fires on every `.active` transition so
    /// `reconcileAppIcon()` runs regardless of which view is visible.
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Crash-recovery gate is established by `CeciliasNotesAppDelegate`
        // BEFORE SwiftUI instantiates this struct — see
        // `application(_:didFinishLaunchingWithOptions:)`. By the
        // time `init` runs, `LaunchRecovery.previousShutdownWasClean`
        // is already populated and the persisted flag has been
        // flipped to `false`.

        MainThreadWatchdog.install()

        // Production hang/crash telemetry — the OS delivers MetricKit
        // diagnostics (with stacks) on the launch after an incident,
        // written to Documents/Diagnostics. DEBUG builds have the
        // watchdog + forensics logs; this is the Release-build eye.
        #if canImport(MetricKit) && os(iOS)
        MainActor.assumeIsolated { MetricKitCollector.shared.start() }
        #endif

        // Fix 2 — instantiate the icon-update gate at launch so its
        // keyboard-lifecycle observers are installed BEFORE the
        // onboarding name field can raise the keyboard. Created late,
        // the gate can't tell a keyboard is already up and would
        // fire the icon swap early — back into the EAGAIN failure.
        MainActor.assumeIsolated { IconUpdateGate.shared.prime() }

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
        // "-uiTesting" argument, wipe every persisted ceciliasnotes.* /
        // app.user / app.onboarding key AND the on-disk SwiftData store
        // so each UI test starts from a clean state. Resume is also
        // force-disabled so a UI test run never lands inside an editor
        // it didn't open itself.
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
            where key.hasPrefix("ceciliasnotes.")
               || key.hasPrefix("app.user")
               || key.hasPrefix("app.onboarding") {
            defaults.removeObject(forKey: key)
        }
        // Force resume off for UI tests so a stale lastNotebookId
        // doesn't interfere even on the first launch after install.
        defaults.set(false, forKey: "ceciliasnotes.resume.enabled")

        // Wipe the on-disk SwiftData store. We attempt to remove the
        // entire `CeciliasNotes` Application Support directory: it contains the
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
                    UserDefaults.standard.removeObject(forKey: "ceciliasnotes.eraser.pixelSize.session")
                    UserDefaults.standard.removeObject(forKey: "ceciliasnotes.eraser.pixelSize")

                    // One-time defensive recompute of `totalPageCount`
                    // for any pre-existing notebooks whose denormalised
                    // count drifted from the live page list. Gated by a
                    // UserDefaults flag — subsequent launches no-op.
                    storageService.runOneTimePageCountBackfillIfNeeded()

                    // Duplicate purge + soft-delete reconcile already
                    // ran in `StorageService.init` before the first
                    // frame. Re-running here duplicated work and
                    // produced REVERTED churn on the main thread.

                    // Quiz auto-update: grow any `autoUpdateEnabled`
                    // quizzes from new note content on a weekly cadence.
                    // Detached + silent — never blocks the first frame.
                    QuizAutoUpdater.runOnLaunch()

                    // Media sync backfill: copy the bytes of any
                    // pre-existing image / audio rows into their
                    // SwiftData `@Attribute(.externalStorage)` data
                    // columns so they flow through CloudKit going
                    // forward. Idempotent — guarded by UserDefaults
                    // flag, no-op after first successful run.
                    MediaSyncBackfill.runIfNeeded()

                    // MCP mirror backfill + refresh. Walk every
                    // live notebook on launch and rewrite its
                    // mirror file. This is the single hook that
                    // both seeds the mirror for any notebook
                    // created before the MCP feature shipped
                    // (the "8 notebooks, 2 mirror files" case)
                    // AND captures any edits made between the
                    // last `applicationDidEnterBackground` pass
                    // and a fresh launch. Cheap — one short
                    // JSON write per notebook, off the main
                    // actor.
                    CeciliasNotesExporter.shared.scheduleExportAll()

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

                    // Step 10: orphan-cleanup sweep. Background-
                    // priority — each per-category pass walks the
                    // on-disk file list once + queries SwiftData for
                    // active references. Files past the 30-day
                    // grace window AND unreferenced get hard-deleted.
                    // Idempotent and safe to repeat (the grace gate
                    // skips fresh files; the reference check skips
                    // currently-used ones).
                    Task.detached(priority: .background) {
                        await MainActor.run {
                            MediaStorage.purgeAllOrphans(
                                context: StorageService.shared.context
                            )
                        }
                    }

                    // .inkbook ingest: watch the iCloud Inbox folder
                    // for files dropped by external agents (e.g. the
                    // cecilias-notes-mcp server running on macOS).
                    // Idempotent; safe to call on every cold launch.
                    CeciliasNotesFileWatcher.shared.start()

                    // Multipeer-direct ingest: when the user has
                    // opted in (Settings → cloud → "Receive from
                    // Mac on this network"), advertise the
                    // _cn-sync._tcp service so the Mac MCP can ship
                    // a notebook directly over LAN / Bluetooth PAN,
                    // much faster than iCloud sync. No-op when the
                    // toggle is off.
                    _ = MultipeerSyncService.shared

                    // Multipeer browse lane: when this device has
                    // paired peers or is signed into iCloud (household
                    // auto-pair), actively look for the other devices
                    // instead of waiting to be found. This is what
                    // lets an iPhone and an iPad on the same Wi-Fi
                    // form the live link without a Mac in the room.
                    // Gated on the same `receive on local network`
                    // preference as the advertiser: when the user turns
                    // multipeer OFF, the browse lane must not keep
                    // chasing paired peers — an unreachable-but-still-
                    // advertised device otherwise drives an endless
                    // "Failed to send a DTLS packet / No route to host"
                    // storm that degrades the whole app on-device.
                    if MultipeerSyncService.shared.isEnabled,
                       !MultipeerPairingStore.pairedPeerNames().isEmpty
                        || MultipeerPairingStore.householdTokenHash() != nil {
                        MultipeerSendService.shared.startBackgroundReconnect()
                    }

                    // Share-extension ingest: watch the app-group
                    // ShareInbox for files dropped by the iOS share
                    // sheet (Files → Cecilia's Notes, Safari → Cecilia's
                    // Notes, etc.). Idempotent; safe to call on every
                    // cold launch.
                    ShareInboxWatcher.shared.start()

                    // Launch-time notebook resume. The previous rule
                    // — "never restore nav state across cold launches"
                    // — was revised after device testing: users who
                    // background a notebook and have iOS suspend +
                    // terminate the app expect to land back in that
                    // notebook on next open, not be silently bounced
                    // to library home. The standard iOS pattern that
                    // distinguishes "the system killed me" from
                    // "the user explicitly force-quit" is the
                    // clean-shutdown gate already in place via
                    // `LaunchRecovery` — background fires
                    // `applicationDidEnterBackground` (marker → true);
                    // force-quit / crash skip it (marker stays
                    // false). On launch, if the gate is clean AND
                    // a `ceciliasnotes.resume.lastNotebookId` survives in
                    // defaults (cleared on explicit Back via
                    // `EditorViewModel.prepareForDismissal`), route
                    // through the deep-link router so the library
                    // pops the editor cover for that notebook.
                    if !didAttemptLaunchResume {
                        didAttemptLaunchResume = true
                        let resumeOn = UserDefaults.standard
                            .object(forKey: "ceciliasnotes.resume.enabled") as? Bool ?? true
                        if LaunchRecovery.previousShutdownWasClean,
                           resumeOn,
                           let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.resume.lastNotebookId"),
                           let lastId = UUID(uuidString: raw) {
                            #if DEBUG
                            dlog("[Launch] clean shutdown + lastNotebookId=\(lastId) — routing to editor")
                            #endif
                            // Defer one runloop tick so the library
                            // has a chance to mount its `.onChange`
                            // observer before the deep-link value
                            // flips.
                            DispatchQueue.main.async {
                                deepLink.openNotebookId = lastId
                            }
                        }
                    }
                }
                // Foreground-return icon reconcile. Idempotent —
                // returns immediately if the live icon already
                // matches the desired one. The reason this exists
                // in addition to `LibraryView.onAppear`: if iOS
                // suspends the app inside the editor, returning to
                // foreground doesn't re-fire library's `.onAppear`,
                // and a failed-during-onboarding swap would sit
                // there until the user backed out to library.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        reconcileAppIcon()
                        // Cross-device hygiene on every return to
                        // foreground: another device (iPhone records
                        // a note, iPad edits the same notebook, both
                        // import the same Inbox .inkbook) may have
                        // synced rows in while we were backgrounded.
                        // The launch-only sweep left a window where a
                        // duplicated primary key could crash iOS 26's
                        // ForEach until the next cold start.
                        scheduleDuplicateSweep()
                    }
                }
                // Mid-session CloudKit deliveries — SwiftData's
                // CloudKit stack posts NSPersistentStoreRemoteChange
                // as remote records land. Debounced: imports arrive
                // in bursts and the sweep only needs to run once per
                // batch.
                .onReceive(
                    NotificationCenter.default
                        .publisher(for: .NSPersistentStoreRemoteChange)
                        .receive(on: DispatchQueue.main)
                ) { _ in
                    scheduleDuplicateSweep()
                }
                // Spotlight launch
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                       let uuid = SpotlightService.notebookId(fromIdentifier: id) {
                        deepLink.openNotebookId = uuid
                    }
                }
                .onContinueUserActivity(PageHandoff.activityType) { activity in
                    guard let payload = PageHandoff.parse(activity.userInfo) else { return }
                    deepLink.openNotebookId = payload.notebookId
                    deepLink.openPageId = payload.pageId
                }
                // ceciliasnotes:// deep links
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

    /// Debounced duplicate-row + soft-delete sweep. Coalesces the
    /// burst of `NSPersistentStoreRemoteChange` notifications a
    /// CloudKit import batch produces into one pass, two seconds
    /// after the last event. The sweep itself is a few fetches and
    /// a Dictionary group — cheap enough to run opportunistically,
    /// too expensive for every notification.
    private func scheduleDuplicateSweep() {
        Self.pendingDuplicateSweep?.cancel()
        let storage = storageService
        Self.pendingDuplicateSweep = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            storage.purgeDuplicateRows()
            let skipReconcile = StorageService.launchHygieneCompletedAt.map {
                Date().timeIntervalSince($0) < 60
            } ?? false
            if !skipReconcile {
                storage.reconcileSoftDeleteFlags()
            }
        }
    }

    /// Held statically because `App` structs are value types —
    /// storing the task in `@State` would need a binding writable
    /// from `body`, and there is exactly one app instance.
    private static var pendingDuplicateSweep: Task<Void, Never>?

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

        let storeURL = StorageService.ceciliasNotesDirectoryURL
            .appendingPathComponent("ceciliasnotes.sqlite")
        try? FileManager.default.createDirectory(
            at: StorageService.ceciliasNotesDirectoryURL,
            withIntermediateDirectories: true
        )
        // Truncate the WAL before SwiftUI touches `StorageService.shared`.
        // A multi-MB sidecar from an unclean shutdown makes every
        // subsequent `ModelContainer` open and mainContext read wedge
        // the main runloop — the #1 cause of "unresponsive after re-open".
        DispatchQueue.global(qos: .userInitiated).sync {
            ModelContainer.truncateWALIfPresent(at: storeURL)
        }

        // A main-thread hang in the prior session is treated like a
        // dirty shutdown even if the user backgrounded before force-
        // quitting — background normally marks shutdown clean, which
        // would otherwise auto-resume the notebook that caused the ANR.
        if SessionHealth.consumeHadHangOnPriorSession() {
            LaunchRecovery.previousShutdownWasClean = false
            defaults.removeObject(forKey: "ceciliasnotes.resume.lastNotebookId")
            defaults.removeObject(forKey: "ceciliasnotes.resume.lastPageIndex")
            #if DEBUG
            dlog("[Launch] prior session had main-thread hang — forcing library home + clearing resume keys")
            #endif
        } else if !prevClean {
            // Clear any stale per-notebook resume pointers so the
            // editor's "resume to last page" path can't restore into
            // the broken session that caused the unclean shutdown.
            defaults.removeObject(forKey: "ceciliasnotes.resume.lastNotebookId")
            defaults.removeObject(forKey: "ceciliasnotes.resume.lastPageIndex")
            #if DEBUG
            dlog("[Launch] previous shutdown was DIRTY — forcing library home + clearing resume keys")
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
            .appendingPathComponent("ceciliasnotes.sqlite")
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-shm", "-wal", "-journal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix)
            )
        }

        defaults.set(true, forKey: v5WipeKey)
        #if DEBUG
        dlog("[Launch] V5 wipe applied — UserDefaults media stores + V4 SwiftData store cleared")
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
            .appendingPathComponent("ceciliasnotes.sqlite")
        try? FileManager.default.removeItem(at: storeURL)
        for suffix in ["-shm", "-wal", "-journal"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: storeURL.path + suffix)
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
        defaults.removeObject(forKey: "ceciliasnotes.resume.lastNotebookId")
        defaults.removeObject(forKey: "ceciliasnotes.resume.lastPageIndex")

        defaults.set(true, forKey: v6WipeKey)
        #if DEBUG
        dlog("[Launch] V6 wipe applied — V5 SwiftData store + Documents/MediaAttachments/ cleared")
        #endif
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Don't mark a hung session as cleanly shut down — otherwise
        // force-quit after an ANR still auto-resumes the bad notebook.
        if !SessionHealth.hadHangThisSession {
            UserDefaults.standard.set(true, forKey: Self.shutdownKey)
        }
        // Reset the dirty-launch streak — reaching background means
        // the launch survived long enough to be useful, so the
        // SwiftData CloudKit auto-fallback shouldn't fire on the
        // next launch. See `ModelContainer.ceciliasNotesContainer`
        // for the consumer.
        UserDefaults.standard.set(0, forKey: "ceciliasnotes.swiftdata.dirtyLaunchStreak")
        // Refresh every notebook's MCP mirror on background — the
        // historical "write mirror once at creation" behaviour left
        // the mirror stale after every page add, ink stroke, or
        // text edit. Backgrounding is the natural sync point where
        // an MCP that's about to read the mirror needs the latest
        // state, so a full re-export here keeps the agent's view
        // consistent without per-mutation plumbing.
        CeciliasNotesExporter.shared.scheduleExportAll()
        #if DEBUG
        dlog("[Launch] applicationDidEnterBackground → marked shutdown clean + queued mirror refresh")
        #endif
    }

    func applicationWillTerminate(_ application: UIApplication) {
        if !SessionHealth.hadHangThisSession {
            UserDefaults.standard.set(true, forKey: Self.shutdownKey)
        }
        UserDefaults.standard.set(0, forKey: "ceciliasnotes.swiftdata.dirtyLaunchStreak")
        // Best-effort: stop any active recording so the .m4a is
        // flushed and finalizeDictation runs before the process exits.
        // This path is only reached when iOS terminates a foreground
        // app (not force-quit, which gets no callback). Swift async
        // tasks aren't guaranteed to finish, but the AVAudioFile
        // flush and the SwiftData save are fast enough in practice.
        Task { @MainActor in
            await RecordingSession.shared.stop()
            CeciliasNotesExporter.shared.scheduleExportAll()
        }
        #if DEBUG
        dlog("[Launch] applicationWillTerminate → stopped recording + marked shutdown clean + queued mirror refresh")
        #endif
    }
}

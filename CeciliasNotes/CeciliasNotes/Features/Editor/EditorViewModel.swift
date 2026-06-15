import AVFoundation
import Combine
import Foundation
import PencilKit
import SwiftData
import SwiftUI
import UIKit

// MARK: - SaveStatus

enum SaveStatus: Equatable {
    case idle
    case saving
    case saved        // shown briefly (1s) then transitions back to idle
    case error(String)
}

// MARK: - RecordingState

enum RecordingState {
    case idle
    case recording
    case processing
}

// MARK: - EditorViewModel

@MainActor
final class EditorViewModel: ObservableObject {

    // MARK: Identity / data
    let notebook: Notebook
    @Published private(set) var pages: [Page]
    @Published var currentPageIndex: Int

    var currentPage: Page { pages[currentPageIndex] }

    /// Direction of the most-recent page navigation. Read by
    /// `CanvasContainerView` to drive the slide transition.
    enum SwapDirection { case forward, backward }
    var lastSwapDirection: SwapDirection = .forward

    // MARK: Toolbar / chrome visibility
    @Published var isToolbarVisible: Bool = true

    /// Three-state visibility for the redesigned notebook header. The
    /// header drops as soon as the user starts writing; the user can
    /// reveal it again by tapping the 3pt return bar at the top of the
    /// canvas or swiping down from the top edge, after which it hides
    /// itself again two seconds into resumed writing.
    @Published var headerVisibility: HeaderVisibility = .visible
    private var headerManualReHideTask: Task<Void, Never>?

    /// Reasons the header should stay visible regardless of stroke
    /// activity. While any reason is active the auto-hide path is
    /// suppressed; when the last one ends, a 3-second grace timer keeps
    /// the header up so the user can read what just happened
    /// (recording finished, share sheet dismissed, etc.) before it
    /// drops back. Sources opening these interactions are also expected
    /// to bring a hidden header back into view via
    /// `beginInteraction(_:)`.
    enum InteractionReason: Hashable {
        case recordingPanel
        case undoRedo
        case customisePanel
        case shareSheet
        case pageStrip
    }
    @Published private(set) var activeInteractions: Set<InteractionReason> = []
    private var interactionGraceTask: Task<Void, Never>?
    @Published var isShowingPageStrip: Bool = false {
        didSet {
            guard oldValue != isShowingPageStrip else { return }
            if isShowingPageStrip { beginInteraction(.pageStrip) }
            else                  { endInteraction(.pageStrip) }
        }
    }
    @Published var isFullScreen: Bool = false
    private var toolbarHideTask: Task<Void, Never>?

    /// Distraction-free writing mode. When true, the editor toolbar, page
    /// strip, and minimap fade out; the tool palette dims to 30%; status
    /// bar and home indicator are hidden. The canvas stays fully
    /// interactive. Exits automatically on returning to Library.
    /// (Auto-hide-then-restore-on-edge-tap of the palette is a deferred
    /// follow-up — for now the palette stays at 30% opacity.)
    @Published var isFocusMode: Bool = false

    /// User-driven palette visibility. Independent of Focus Mode
    /// (which dims the palette to 30%) and Full Screen (which hides
    /// it together with the rest of the chrome). Defaults to visible;
    /// the toolbar's palette toggle flips it.
    @Published var isToolPaletteHidden: Bool = false

    // MARK: Pencil Pro squeeze radial wheel
    /// Drives the radial wheel overlay. Nil = wheel hidden.
    @Published var squeezeWheelCentre: CGPoint?

    // MARK: Tool state
    @Published var selectedTool: CeciliasNotesTool
    @Published private(set) var lastTool: CeciliasNotesTool?         // for "switch between two tools"

    // MARK: State machine (Phase 5E)
    //
    // Single consolidation point for the editor's high-level mode —
    // see `EditorStateMachine.swift`. Tool identity + settings stay
    // on `selectedTool`; this machine owns the orthogonal mode axis
    // (lecture recording, audio recording, text-block edit, image
    // selection, sticky-note edit) and the `canvasIsInteractive`
    // signal the canvas reads to decide whether to take Pencil input.
    //
    // Existing call sites still mutate `activeLectureRecorder`,
    // `activeMediaSource`, `recordingState`, `selectedAttachmentIds`
    // directly. The `didSet` hooks on those properties mirror the
    // transition into `stateMachine` so the mode stays in sync
    // without rewriting every call site. New code should call
    // `stateMachine.enterMode(_:)` / `exitMode()` directly.
    let stateMachine = EditorStateMachine()

    /// Single source of truth the canvas reads to gate Pencil input.
    /// Combines tool-type signal (`selectedTool.isDrawingTool`) with
    /// the mode signal (`stateMachine.mode == .drawing`).
    ///
    /// Read-only devices (iPhone) **always** report inactive — the
    /// canvas never accepts touches even if a tool somehow became
    /// active. Defense in depth: the tool palette is hidden on the
    /// same devices so `selectedTool` should never be a drawing
    /// tool there anyway, but this guard means a keyboard shortcut
    /// / deep-link / hot-reload race can't slip through.
    var canvasIsInteractive: Bool {
        guard DeviceCapabilities.canDraw else { return false }
        return stateMachine.canvasIsInteractive(toolIsDrawing: selectedTool.isDrawingTool)
    }
    @Published var activePencilDoubleTapAction: PencilDoubleTapAction = .toggleEraser
    /// `UserDefaults.didChangeNotification` token. Released in `deinit`.
    /// Drives the mid-session refresh of `activePencilDoubleTapAction`
    /// when the user changes the setting in Settings → Pencil with the
    /// editor still open. See §6.E.
    private nonisolated(unsafe) var userDefaultsObserver: NSObjectProtocol?
    @Published var isShowingColorPicker: Bool = false

    // MARK: Zoom
    @Published var zoomScale: CGFloat = 1.0

    // MARK: Save state
    @Published private(set) var isDirty: Bool = false
    @Published private(set) var saveStatus: SaveStatus = .idle
    private var saveTask: Task<Void, Never>?
    private var savedFlashTask: Task<Void, Never>?

    // MARK: Drawing accessor — set by CanvasContainerView coordinator after makeUIView
    weak var canvasView: PKCanvasView?

    /// Transport struct for the normalised tap location the user
    /// wants the imported image centred on. Used as the `at:`
    /// argument to `commitImportedImage` from every entry point
    /// (canvas tap, long-press, drag-drop, toolbar centre-import).
    /// Picker presentation itself runs from `LibraryView` at the
    /// root level, driven by `LibraryViewModel.pendingImageImport`
    /// and the `.imageImportRequested` / `.imageImportCompleted`
    /// notifications — see `ImageImportNotifications.swift`.
    struct ImageImportRequest: Identifiable {
        let id = UUID()
        let normalizedX: Double
        let normalizedY: Double
    }

    /// Open the import picker centred on the current page. Posts
    /// `.imageImportRequested`; `LibraryViewModel` observes and
    /// flips its `pendingImageImport` state, which drives the
    /// library-root `.sheet(item:)`. Picker resolution comes back
    /// here via `handleImageImportCompleted` (the
    /// `.imageImportCompleted` observer set up in `init`).
    func requestImageImportCentred() {
        NotificationCenter.default.post(
            name: .imageImportRequested,
            object: nil,
            userInfo: [
                ImageImportUserInfoKey.normalizedX: 0.5,
                ImageImportUserInfoKey.normalizedY: 0.5,
            ]
        )
    }

    /// Commit a picked image as a V6 `PageElement(kind: .image)` +
    /// `ImageContent`. The file is written under
    /// `Documents/MediaAttachments/images/<id>.<ext>` (shared
    /// iCloud Drive layout via `MediaStorage`); the element is
    /// sized to ~60% of page width preserving aspect ratio,
    /// positioned so its centre lands on `(normalizedX, normalizedY)`.
    ///
    /// Step 4 rewired this method onto the unified model — the
    /// legacy `ImageRecord` + `MediaAttachmentStore.save` flow was
    /// removed in the same commit. The element renders
    /// immediately via `ImageElementsOverlayView` once the
    /// `mediaAttachmentsChanged` notification fires below.
    func commitImportedImage(
        _ image: UIImage,
        fileExtension ext: String,
        at request: ImageImportRequest
    ) {
        let attachmentId = UUID()
        let safeExt = ext.isEmpty ? "jpg" : ext.lowercased()

        // Aspect-preserving fit to ~60% of page width.
        let pixelWidth  = max(1, image.size.width)
        let pixelHeight = max(1, image.size.height)
        let aspect = pixelHeight / pixelWidth
        let targetW: Double = 0.6
        let targetH: Double = Double(aspect) * targetW

        let normalizedX = max(0, min(1 - targetW, request.normalizedX - targetW / 2))
        let normalizedY = max(0, min(1 - targetH, request.normalizedY - targetH / 2))

        // The disk write is awaited before the element/content are
        // inserted into SwiftData. The render path's `ImageDataView`
        // decodes on first paint via `.task(id:)`; if the row lands
        // before the file does, the loader resolves a missing file
        // and the placeholder sticks until a tool change forces a
        // re-render. Sequencing the writes keeps the two in step.
        let format: MediaStorage.ImageFormat =
            safeExt == "png" ? .png : .jpeg(quality: 0.85)
        let pageId = currentPage.id
        let notebookId = notebook.id
        Task { @MainActor in
            // Write to disk AND capture the bytes so the SwiftData
            // row can carry them under `@Attribute(.externalStorage)`.
            // That's the column CloudKit promotes to a CKAsset, so
            // the image rides the same sync pipeline as the row
            // itself — present on every signed-in device, and
            // readable by AI consumers without filesystem lookups.
            guard let written = await MediaStorage.writeImageReturningBytes(
                image, id: attachmentId, format: format
            ) else { return }

            let context = StorageService.shared.context
            let element = PageElement(
                id: UUID(),
                pageId: pageId,
                notebookId: notebookId,
                kind: .image,
                normalizedX: normalizedX,
                normalizedY: normalizedY,
                normalizedWidth: targetW,
                normalizedHeight: targetH
            )
            let content = ImageContent(
                id: attachmentId,
                filename: "\(attachmentId.uuidString).\(safeExt)",
                fileFormat: safeExt,
                originalPixelWidth: Int(pixelWidth),
                originalPixelHeight: Int(pixelHeight),
                imageData: written.data
            )
            element.imageContent = content
            context.insert(element)
            do {
                try context.save()
            } catch {
                #if DEBUG
                print("[Image] save failed on commitImportedImage: \(error)")
                #endif
            }
            NotificationCenter.default.post(
                name: .mediaAttachmentsChanged, object: nil
            )
        }
    }

    /// Annotation pulse signal. Set to a `PageElement(.highlight).id`
    /// or `PageElement(.stickyNote).id` to make that mark pulse once
    /// on the canvas (scale 1.0 → 1.1 → 1.0 over 0.3s). Driven by
    /// the annotation list sheet's row tap after page-scroll settles.
    /// Step 7 retired the legacy `StickyNoteMarker` reader; current
    /// consumers are pending Step 8/9 reintroduction on the V6
    /// overlays.
    @Published var pulsingAnnotationId: UUID?

    /// PDF annotation writer for the current notebook session, or
    // Step 5.5: `PDFAnnotationWriter` was retired. Highlights live
    // entirely inside the app as `PageElement(.highlight)` rows;
    // they don't round-trip into the source PDF on disk because the
    // PDF file is shared across notebooks via hash dedup
    // (`MediaStorage.pdfs/<pdfDocumentId>.pdf`). Export
    // (`ExportService`) still stamps highlights as proper
    // `PDFAnnotation` objects on the exported copy.

    /// Stroke count on the active canvas — used for VoiceOver labels.
    var strokeCount: Int { canvasView?.drawing.strokes.count ?? 0 }

    // MARK: Recent colours (persisted)
    @Published private(set) var recentColours: [UIColor] = []

    // MARK: Notebook title editing
    @Published var isEditingTitle: Bool = false

    // MARK: Customise pill + panel (Item 1)

    /// Whether the floating "Customise" pill is currently visible. Driven
    /// by `EditorView.onAppear` via `markCustomisePillIfFresh()` for newly-
    /// created notebooks, and auto-dismissed after 5 seconds.
    @Published var isCustomisePillVisible: Bool = false

    /// Whether the slide-down Customise panel is open. Tapping the pill,
    /// the title bar, or "Customise Notebook…" in the More menu sets this.
    @Published var isCustomisePanelOpen: Bool = false

    /// When `true`, the customise panel should focus the notebook
    /// name field on appear. Set by `EditorView.onAppear` when the
    /// notebook id was marked by
    /// `NewNotebookCustomiseTrigger.mark(_:)` (the
    /// "+ new notebook → open notebook → auto-open customise"
    /// flow). The panel reads + clears this on appear so a
    /// subsequent manual re-open doesn't steal focus.
    @Published var pendingCustomiseNameFocus: Bool = false

    /// Notebook IDs that have already been shown a pill in this session.
    /// Session-local — not persisted; we don't want pills resurfacing on
    /// every cold launch. Static so it survives across editor view-model
    /// instances within a single app run.
    private static var pillShownIds: Set<UUID> = []

    /// Notebook IDs that should never trigger the customise pill —
    /// PDF / image imports stamp this so a freshly-created
    /// import-target notebook doesn't surface the "Customise" pill
    /// the user never asked for. Survives across editor view-model
    /// instances within a single run.
    private static var suppressedPillIds: Set<UUID> = []

    /// Mark a notebook ID so `markCustomisePillIfFresh` will skip
    /// it. Call from any non-user-initiated notebook-creation path
    /// (PDF import, image import, etc.).
    static func suppressCustomisePill(for id: UUID) {
        suppressedPillIds.insert(id)
    }

    /// Tool the editor will swap to the moment a pencil touch is
    /// observed this session. Resolved at init from the user's
    /// persisted last-inking choice (or pen). Nilled after consumption
    /// so a subsequent manual return to cursor doesn't re-swap on the
    /// next pencil hover.
    private var pendingInkingToolForPencil: CeciliasNotesTool?

    /// Called from `EditorView.onAppear`. Shows the pill iff the notebook
    /// was created within the last 30 seconds AND we haven't already shown
    /// the pill for it this session. The 5-second auto-dismiss is owned
    /// by the pill view itself (it has the timing context).
    func markCustomisePillIfFresh() {
        guard !Self.pillShownIds.contains(notebook.id) else { return }
        guard !Self.suppressedPillIds.contains(notebook.id) else { return }
        let age = Date().timeIntervalSince(notebook.createdAt)
        guard age < 30 else { return }
        Self.pillShownIds.insert(notebook.id)
        isCustomisePillVisible = true
    }

    func dismissCustomisePill() {
        isCustomisePillVisible = false
    }

    func openCustomisePanel() {
        isCustomisePillVisible = false
        isCustomisePanelOpen   = true
        beginInteraction(.customisePanel)
        // Surface AI suggestions for the user as they enter the
        // editing surface. Both methods are idempotent — they no-op
        // when conditions aren't met (AI off, already generated this
        // session, dismissed flag set, etc.).
        maybeGenerateTitleSuggestion()
        maybeGenerateTagSuggestions()
    }

    func closeCustomisePanel() {
        // Resign first responder before the panel slides away so
        // the keyboard can't get stranded above the canvas if the
        // user dismissed via tap-outside (not the "done" button).
        // Idempotent — `sendAction(_:to: nil)` no-ops when no
        // responder is focused.
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil, from: nil, for: nil
        )
        isCustomisePanelOpen = false
        endInteraction(.customisePanel)
    }

    // MARK: Export
    @Published var isShowingExportSheet: Bool = false {
        didSet {
            guard oldValue != isShowingExportSheet else { return }
            if isShowingExportSheet { beginInteraction(.shareSheet) }
            else                    { endInteraction(.shareSheet) }
        }
    }

    // MARK: Page navigation animation
    @Published var pageSwapInFlight: Bool = false        // shown only if swap exceeds 100ms

    // MARK: Text blocks
    @Published private(set) var currentPageTextBlocks: [TextBlock] = []

    // MARK: Media attachments
    //
    // Phase 5A+5C Step 1: the SwiftData `MediaAttachment` entity is
    // gone. Image rendering / interaction lives entirely in
    // `ImageAttachmentsView`, backed by `MediaAttachmentStore`
    // (UserDefaults JSON). The previous per-page array, undo stack,
    // and the half-dozen passthrough mutation methods on this
    // view-model were callers of the deleted entity and have been
    // removed.
    @Published var selectedAttachmentIds: Set<UUID> = []
    @Published var mediaError: String?

    /// Structured user-visible error. Surfaced via `MediaErrorBanner` alongside
    /// `mediaError`. Prefer this for new error sites — the string-typed
    /// `mediaError` predates `AppError` and is kept only for in-flight call sites.
    @Published var error: AppError?

    /// Funnels structured errors through the existing banner UI.
    func showError(_ appError: AppError) {
        self.error = appError
    }

    /// Drives the media picker sheet — set by MediaInsertCoordinator
    /// methods. Phase 5E mirror: this isn't itself a mode (it's a
    /// modal-presentation flag), so we don't reflect it in the
    /// state machine. Listed here for completeness because the
    /// nearby mode-bearing flags below DO mirror in their didSets.
    @Published var activeMediaSource: MediaSource?

    // MARK: Media insert coordinator (lazy to break init cycle)
    lazy var mediaInsertCoordinator: MediaInsertCoordinator = MediaInsertCoordinator(viewModel: self)

    // MARK: Sticky notes
    //
    // Step 7 migrated sticky notes onto the unified PageElement
    // model — `PageElement(kind: .stickyNote) + StickyNoteContent`.
    // The per-page `StickyNoteElementsOverlayView` queries
    // SwiftData directly, so the view-model no longer caches a
    // `currentPageStickyNotes` array. The only sticky-related state
    // that stays on the view-model is `editingStickyNoteId`, which
    // mirrors into `EditorStateMachine.stickyNoteEditing(_:)` for
    // mode tracking.

    // Step 6: V5 `activeLectureRecorder` removed. Dictation is
    // owned by `RecordingSession.shared`; the editor no longer
    // swaps its body for a full-screen lecture view. Recording
    // happens in-place on a fresh dictation page.
    /// Mirrored from the per-page sticky overlay when a sticky
    /// enters edit mode. Drives the state machine's
    /// `.stickyNoteEditing(noteId:)` mode so canvas Pencil input
    /// suppresses correctly while the keyboard is up.
    @Published var editingStickyNoteId: UUID? {
        didSet {
            if let id = editingStickyNoteId, oldValue == nil {
                stateMachine.enterMode(.stickyNoteEditing(noteId: id))
            } else if editingStickyNoteId == nil, oldValue != nil {
                if case .stickyNoteEditing = stateMachine.mode {
                    stateMachine.exitMode()
                }
            }
        }
    }

    // MARK: AI — suggested title (Phase 2)

    /// Latest AI-generated title proposal for an untitled notebook.
    /// Surfaced as a pill under the title TextField in the customise
    /// panel; cleared once the user either accepts it or commits a
    /// manual title.
    @Published private(set) var suggestedTitle: String?
    private var hasGeneratedTitleSuggestion = false

    /// True when the notebook's current title is a stock placeholder
    /// the AI is allowed to overwrite. Generator-named notebooks
    /// (e.g. "Brain Dump") are user-chosen even if playful, so we
    /// only count empty / "Untitled" as eligible.
    private var titleLooksLikePlaceholder: Bool {
        let trimmed = notebook.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.lowercased() == "untitled"
    }
    // Step 6: V5 `isRecordingPanelVisible` removed alongside
    // `RecordingPanelView`. Voice Note recording renders as an
    // inline pulsing strip via `AudioElementView`'s recording
    // state; the global timer + stop live on
    // `FloatingRecordingControls` driven by `RecordingSession`.
    @Published var recordingState:              RecordingState = .idle {
        didSet {
            // Phase 5E mirror: quick-record session is a state-
            // machine mode. Only `.recording` blocks other long-
            // form sessions; `.idle` (and the transient `.paused`)
            // both fall back to `.drawing`.
            guard recordingState != oldValue else { return }
            #if DEBUG
            let stack = Thread.callStackSymbols.prefix(5).joined(separator: "\n  ")
            print("[RecordingMirror] recordingState \(oldValue) → \(recordingState)")
            print("[RecordingMirror]   stack:\n  \(stack)")
            #endif
            switch recordingState {
            case .recording:
                stateMachine.enterMode(.audioRecording(sessionId: UUID()))
            default:
                if case .audioRecording = stateMachine.mode {
                    stateMachine.exitMode()
                }
            }
        }
    }
    /// Defaults from `ceciliasnotes.transcription.auto` (Settings → Audio & Transcription).
    /// User can also override per-recording via the panel toggle while recording.
    @Published var isTranscriptionEnabled: Bool =
        UserDefaults.standard.object(forKey: "ceciliasnotes.transcription.auto") as? Bool ?? true
    @Published var isShowingAudioFilePicker:    Bool      = false

    private var audioRecorder = AudioRecorder()

    // MARK: Keyboard offset — updated by EditorView keyboard notifications
    @Published var keyboardVisibleHeight: CGFloat = 0

    // MARK: Pending exit confirmation (back button while dirty)
    @Published var isShowingExitConfirmation: Bool = false

    // MARK: Shape recognition
    /// User toggle, persists across launches. Default OFF.
    @AppStorage("ceciliasnotes.shape.recognitionEnabled") var shapeRecognitionEnabled: Bool = false

    /// Pending shape replacement — drives the floating "Undo Shape" pill.
    /// Set after a successful detection; cleared on tap-to-undo, tap-to-dismiss,
    /// timeout (3s), or new stroke.
    struct PendingShapeReplacement: Equatable {
        let originalStroke: PKStroke
        let replacementStrokeIndex: Int

        // PKStroke is not Equatable in PencilKit — compare by index since
        // only one replacement is in flight at a time.
        static func == (lhs: PendingShapeReplacement, rhs: PendingShapeReplacement) -> Bool {
            lhs.replacementStrokeIndex == rhs.replacementStrokeIndex
        }
    }
    @Published var pendingShapeUndo: PendingShapeReplacement?

    /// In-flight 600ms recognition timer. Cancelled when a new stroke arrives.
    private var shapeRecognitionTask: Task<Void, Never>?
    /// In-flight 3s pill auto-dismiss timer.
    private var shapePillDismissTask: Task<Void, Never>?

    // MARK: Storage
    private let storage: StorageService
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

    // MARK: Per-tool persisted settings
    /// One blob per app — see `ToolSettingsStore`. Snapshotted on every
    /// selectedTool mutation, restored on identity-switch.
    private var toolSettings = ToolSettingsStore.load()
    private let theme: Theme

    // MARK: Init

    init(
        notebook: Notebook,
        // Default `.shared` is nil-resolved inside the body so the
        // `@MainActor`-isolated singleton is touched on the main actor
        // rather than at the call-site (Swift 6 default-value
        // isolation rules).
        storage: StorageService? = nil,
        userDefaults: UserDefaults = .standard,
        theme: Theme? = nil
    ) {
        self.notebook        = notebook
        let resolvedStorage  = storage ?? .shared
        // Resolve `@MainActor` singletons in the body, not as default
        // arguments — default-value expressions are nonisolated.
        let resolvedTheme    = theme ?? .default
        self.storage         = resolvedStorage
        self.userDefaults    = userDefaults
        self.theme           = resolvedTheme

        let fetched = resolvedStorage.fetchPages(in: notebook)
        // SwiftData should always return at least one page (createNotebook seeds one),
        // but guard for safety. Also dedupe by id — duplicate Page rows
        // (CloudKit echo / stale local replica) make `ForEach` on iOS 26
        // hard-crash with "NativeDictionary.swift:792: Fatal error:
        // Duplicate values for key…" the moment the editor mounts.
        self.pages            = fetched.isEmpty ? [] : Self.dedupedById(fetched)

        // Restore the last viewed page if the resume feature is on AND the page
        // is still in range. The check happens once at init; subsequent changes
        // are written back in `currentPageIndex`'s didSet.
        let resumeOn = userDefaults.object(forKey: "ceciliasnotes.resume.enabled") as? Bool ?? true
        let savedIndex = userDefaults.integer(forKey: "ceciliasnotes.resume.lastPageIndex")
        if resumeOn,
           userDefaults.string(forKey: "ceciliasnotes.resume.lastNotebookId") == notebook.id.uuidString,
           savedIndex >= 0, savedIndex < fetched.count {
            self.currentPageIndex = savedIndex
        } else {
            self.currentPageIndex = 0
        }
        // Land on the neutral cursor so a one-finger drag scrolls the
        // page out of the gate. The first pencil contact (observed via
        // `pencilTouchObserved`) immediately swaps in the user's last
        // inking tool — so the Pencil user is writing the moment they
        // touch down, while the finger-first user can scroll without
        // accidental ink.
        self.selectedTool = .cursor
        // Remember the inking tool we'll swap *to* on first pencil
        // touch this session.
        self.pendingInkingToolForPencil = Self.resolveInitialTool(
            userDefaults: userDefaults,
            toolSettings: toolSettings,
            theme: resolvedTheme
        )

        loadPersistedState(theme: resolvedTheme)

        // Now that init is done, we can mark this notebook as "currently open" —
        // doing it after init avoids racing the init-time resume check above.
        userDefaults.set(notebook.id.uuidString, forKey: "ceciliasnotes.resume.lastNotebookId")
        userDefaults.set(self.currentPageIndex, forKey: "ceciliasnotes.resume.lastPageIndex")

        // Track the open for the Library "recently opened" section.
        // Persisted via StorageService so the change survives a
        // force-quit between this open and the first save inside the
        // editor.
        resolvedStorage.markNotebookOpened(notebook)

        // Persist page navigation, debounced once per second to avoid UserDefaults churn
        // during fast multi-page jumps.
        $currentPageIndex
            .dropFirst()
            .debounce(for: .seconds(1), scheduler: DispatchQueue.main)
            .sink { [weak self] index in
                guard let self else { return }
                self.userDefaults.set(index, forKey: "ceciliasnotes.resume.lastPageIndex")
            }
            .store(in: &cancellables)

        // Mirror RecordingSession's state into the interaction set so
        // the top header stays visible for the entire dictation /
        // voice-note lifecycle. The toolbar's popover already begins
        // `.recordingPanel` while open, but once the user picks a
        // mode the popover dismisses and recording continues — this
        // subscription holds the lock until `state` returns to
        // `.idle`. Same auto-hide-suppression pattern as the
        // customise panel and share sheet.
        RecordingSession.shared.$state
            .map { $0.isRecording }
            .removeDuplicates()
            .sink { [weak self] isRecording in
                guard let self else { return }
                if isRecording {
                    self.beginInteraction(.recordingPanel)
                } else {
                    self.endInteraction(.recordingPanel)
                }
            }
            .store(in: &cancellables)

        resetToolbarTimer()
        refreshCurrentPageTextBlocks()

        // Step 8: pre-warm the in-memory stroke cache with the
        // first few pages of this notebook. Decoding PKDrawing
        // from Data costs ~5–20ms per page; doing it once at
        // open-time keeps page-strip / first-swipe transitions
        // off the SwiftData decode path. Detached background
        // task — does not block init.
        StrokeCache.shared.prewarmNotebook(notebook.id)

        // App-background flush for the PDF annotation writer. We
        // bypass the 3s debounce on background to guarantee no
        // in-flight annotations are lost if the user backgrounds
        // mid-session. No-op for non-PDF notebooks (writer is nil).
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        // Image-import completion. The picker is owned by the
        // library (it lives outside this view-model's
        // navigation destination); a successful pick fires this
        // notification and we route the bytes through
        // `commitImportedImage`. Cancellation has no editor-side
        // side-effect, so we don't observe it here.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleImageImportCompleted(_:)),
            name: .imageImportCompleted,
            object: nil
        )

        // Pencil-touch auto-swap: the editor opens in `.cursor` so
        // one-finger drag scrolls. The moment the user puts the
        // Pencil down, swap in the persisted last-inking tool so
        // they're writing immediately — no toolbar tap required.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePencilTouchObserved),
            name: .pencilTouchObserved,
            object: nil
        )
    }

    @objc private func handlePencilTouchObserved() {
        // Only swap if we're still on the neutral cursor — if the
        // user has already explicitly picked a tool we respect that.
        guard selectedTool.isCursorMode else { return }
        guard let inking = pendingInkingToolForPencil else { return }
        pendingInkingToolForPencil = nil
        selectedTool = inking
    }

    deinit {
        // Tasks captured [weak self] — they will be no-ops after dealloc.
        toolbarHideTask?.cancel()
        headerManualReHideTask?.cancel()
        saveTask?.cancel()
        savedFlashTask?.cancel()
        // Selector-based observers (e.g. handleAppBackground).
        NotificationCenter.default.removeObserver(self)
        // Block-based observer for UserDefaults.didChangeNotification —
        // `removeObserver(self)` does not cover token-returning observers.
        if let token = userDefaultsObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Background-notification handler. `@objc` so it can be
    /// targeted by `NotificationCenter.addObserver(selector:)`.
    /// Step 5.5: legacy `PDFAnnotationWriter` removed — highlights
    /// commit synchronously through `HighlightCommit` so there's
    /// nothing to flush here. Kept as a hook for future async
    /// background work.
    @objc private func handleAppBackground() {}

    /// Image-import completion handler. Reads the picked image +
    /// extension + normalised tap location from the notification's
    /// `userInfo` and routes through `commitImportedImage`. The
    /// library has already cleared its `pendingImageImport` state
    /// by the time this fires (both VMs observe the same
    /// notification independently).
    @objc private func handleImageImportCompleted(_ note: Notification) {
        guard
            let image = note.userInfo?[ImageImportUserInfoKey.image] as? UIImage,
            let ext   = note.userInfo?[ImageImportUserInfoKey.ext]   as? String
        else { return }
        let normX = (note.userInfo?[ImageImportUserInfoKey.normalizedX] as? Double) ?? 0.5
        let normY = (note.userInfo?[ImageImportUserInfoKey.normalizedY] as? Double) ?? 0.5
        commitImportedImage(
            image,
            fileExtension: ext,
            at: ImageImportRequest(normalizedX: normX, normalizedY: normY)
        )
    }

    /// Editor view should call this on dismiss. Step 5.5 removed
    /// the asynchronous `PDFAnnotationWriter` queue — highlight
    /// commits are now synchronous via `HighlightCommit`, so there
    /// is nothing to flush. The method stays as a no-op so the
    /// editor's dismiss path doesn't have to fork on architecture
    /// generation.
    func flushPDFAnnotationsImmediately() async {}

    /// Jump to `pageNumber` (1-indexed), then briefly pulse the
    /// annotation with the given id. Used by the annotation list
    /// sheet's row tap. 0.4s delay before pulse fires lets the
    /// scroll settle so the user sees the highlight in its
    /// final-rendered position. The pulse itself runs ~0.3s, after
    /// which `pulsingAnnotationId` is cleared.
    func revealAnnotation(id: UUID, pageNumber: Int) {
        if let pageIndex = pages.firstIndex(where: { $0.pageNumber == pageNumber }) {
            // Reuse the existing search-result navigation path —
            // `goToPage` updates the published index AND publishes
            // `pendingScrollPageIndex` so the canvas scroll catches up.
            _ = goToPage(index: pageIndex)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self else { return }
            self.pulsingAnnotationId = id
            try? await Task.sleep(for: .milliseconds(350))
            // Only clear if it's still the same id — a second tap
            // landing during the 350ms window shouldn't be cancelled
            // out by the previous tap's cleanup.
            if self.pulsingAnnotationId == id {
                self.pulsingAnnotationId = nil
            }
        }
    }

    // MARK: - Persisted state

    private struct StorageKeys {
        static let recentColours       = "ceciliasnotes.colorPicker.recent"
        // Must stay in lock-step with SettingsViewModel.DoubleTapAction's @AppStorage key.
        static let pencilDoubleTap     = "ceciliasnotes.pencil.doubletap"
        // Identity of the last inking tool the user selected. Restored
        // on editor open so the canvas reopens on a writing tool rather
        // than the neutral cursor. Only inking tools (`hasColour`) are
        // written here — transient modes (cursor/lasso/text/image) never
        // become the reopen default.
        static let lastInkingTool      = "ceciliasnotes.tool.lastInkingIdentity"
    }

    /// Resolves the tool the editor should open with: the user's last
    /// inking tool (with its persisted settings) if one was recorded,
    /// otherwise the default pen. Static so it can run during `init`
    /// before `self` is fully formed.
    private static func resolveInitialTool(
        userDefaults: UserDefaults,
        toolSettings: ToolSettingsStore,
        theme: Theme
    ) -> CeciliasNotesTool {
        if let raw = userDefaults.string(forKey: StorageKeys.lastInkingTool),
           let identity = CeciliasNotesTool.Identity(rawValue: raw) {
            let restored = toolSettings.tool(for: identity, theme: theme)
            // Guard against a stale/invalid persisted value resolving to
            // a non-inking tool — never reopen on cursor et al.
            if restored.hasColour { return restored }
        }
        return CeciliasNotesTool.Defaults.pen(theme: theme)
    }

    private func loadPersistedState(theme: Theme) {
        // Recent colours
        if let hexes = userDefaults.array(forKey: StorageKeys.recentColours) as? [String] {
            recentColours = hexes.map { UIColor(hex: $0) }
        }

        // Pencil double-tap action — honour system preference if set
        refreshPencilDoubleTapActionFromUserDefaults()

        // Reactivity: keep `activePencilDoubleTapAction` in sync with
        // the Settings UI when the user changes the setting *while*
        // the editor is open. Without this observer the value is read
        // once at init and stays stale until the next cold launch —
        // double-tap then fires the previous action even though
        // Settings shows the new one. See
        // `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.E.
        //
        // Squeeze action / squeeze tool are not cached — see
        // `handlePencilSqueeze`, which reads UserDefaults on every
        // squeeze event. They don't need the same observer.
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees this fires on the main
            // thread; `assumeIsolated` lets us call the
            // `@MainActor` method without a Task hop or a warning.
            MainActor.assumeIsolated {
                self?.refreshPencilDoubleTapActionFromUserDefaults()
            }
        }
    }

    /// Idempotent re-read of the double-tap action UserDefault. Safe
    /// to call from anywhere — only mutates `activePencilDoubleTapAction`
    /// if the value actually changed.
    private func refreshPencilDoubleTapActionFromUserDefaults() {
        let next: PencilDoubleTapAction
        if let raw = userDefaults.string(forKey: StorageKeys.pencilDoubleTap),
           let action = PencilDoubleTapAction(rawValue: raw) {
            next = action
        } else if let mapped = PencilDoubleTapAction.from(UIPencilInteraction.preferredTapAction) {
            next = mapped
        } else {
            return
        }
        if activePencilDoubleTapAction != next {
            activePencilDoubleTapAction = next
        }
    }

    private func persistRecentColours() {
        let hexes = recentColours.map { $0.hexString }
        userDefaults.set(hexes, forKey: StorageKeys.recentColours)
    }

    // MARK: - Toolbar auto-hide

    func resetToolbarTimer() {
        toolbarHideTask?.cancel()
        if !isToolbarVisible {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) { isToolbarVisible = true }
        }
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) {
                    self.isToolbarVisible = false
                }
            }
        }
    }

    func keepToolbarVisible() {
        toolbarHideTask?.cancel()
        if !isToolbarVisible {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) { isToolbarVisible = true }
        }
    }

    // MARK: - Header visibility (redesigned auto-hide)

    /// Notify the visibility state machine that the user has begun a
    /// PencilKit stroke. Drives the spec'd transitions:
    ///   • `.visible`        → `.hiddenWhileWriting` immediately
    ///   • `.visibleManual`  → `.hiddenWhileWriting` 2 seconds later,
    ///     to "not fight the user" who just revealed the bar.
    ///   • `.hiddenWhileWriting` → no-op.
    ///
    /// Suppressed entirely when the per-notebook auto-hide preference
    /// is off, when an interaction (mic, share, customise panel, page
    /// strip, undo/redo) is active, or while the 3-second post-
    /// interaction grace window is still running.
    func notifyHeaderStrokeBegan() {
        guard notebook.autoHideHeader else { return }
        guard activeInteractions.isEmpty else { return }
        guard interactionGraceTask == nil else { return }
        switch headerVisibility {
        case .visible:
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                headerVisibility = .hiddenWhileWriting
            }
        case .visibleManual:
            // First stroke after a manual reveal arms the 2-second
            // re-hide. If a previous re-hide is already armed, replace
            // it so the timer always counts from the latest stroke.
            headerManualReHideTask?.cancel()
            headerManualReHideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                        self.headerVisibility = .hiddenWhileWriting
                    }
                }
            }
        case .hiddenWhileWriting:
            break
        }
    }

    /// User tapped the 3pt return bar or swiped down from the top edge.
    /// Promotes the header back into view; subsequent stroke activity
    /// will re-hide after a 2-second grace window.
    func revealHeaderManually() {
        headerManualReHideTask?.cancel()
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
            headerVisibility = .visibleManual
        }
    }

    /// Mark the start of an interaction that should keep the header
    /// visible — mic recording, share sheet, customise panel, page
    /// strip, an undo/redo button tap. While any interaction is
    /// active, stroke-driven auto-hide is suppressed and any pending
    /// re-hide / grace timer is cancelled. If the header is currently
    /// hidden, it slides back into view so the user can see the chrome
    /// that the interaction relates to.
    func beginInteraction(_ reason: InteractionReason) {
        interactionGraceTask?.cancel()
        interactionGraceTask = nil
        headerManualReHideTask?.cancel()
        activeInteractions.insert(reason)
        if !headerVisibility.isHeaderVisible {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                headerVisibility = .visibleManual
            }
        }
    }

    /// Mark the end of an interaction. When the last interaction ends,
    /// the header stays visible for an additional 3 seconds — the
    /// post-interaction grace window — then drops if auto-hide is
    /// enabled. Calling `beginInteraction(_:)` again during the grace
    /// window cancels the pending hide.
    func endInteraction(_ reason: InteractionReason) {
        activeInteractions.remove(reason)
        guard activeInteractions.isEmpty else { return }
        interactionGraceTask?.cancel()
        interactionGraceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                self.interactionGraceTask = nil
                guard self.notebook.autoHideHeader,
                      self.activeInteractions.isEmpty else { return }
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                    self.headerVisibility = .hiddenWhileWriting
                }
            }
        }
    }

    /// Briefly mark an interaction so the bar persists for the 3s
    /// grace window — used by undo/redo button taps which have no
    /// "open" / "close" lifecycle of their own.
    func pulseInteraction(_ reason: InteractionReason) {
        beginInteraction(reason)
        endInteraction(reason)
    }

    /// Called when the per-notebook `autoHideHeader` preference flips.
    /// When the user disables auto-hide, snap the header back into
    /// view immediately and cancel any pending re-hide work.
    func notifyAutoHidePreferenceChanged() {
        // `notebook.autoHideHeader` is a computed property over the
        // side-channel `NotebookPreferencesStore`. Setting it does NOT
        // trigger @Published / @Model observation, so SwiftUI doesn't
        // know to re-evaluate. Explicit `objectWillChange` makes the
        // toolbar's pin icon and the customise-panel toggle flip
        // visually the moment the user taps.
        objectWillChange.send()
        guard !notebook.autoHideHeader else { return }
        headerManualReHideTask?.cancel()
        interactionGraceTask?.cancel()
        interactionGraceTask = nil
        if !headerVisibility.isHeaderVisible {
            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.snappy)) {
                headerVisibility = .visible
            }
        }
    }

    // MARK: - Focus Mode

    func toggleFocusMode() {
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
            isFocusMode.toggle()
        }
    }

    // MARK: - Pencil Pro squeeze wheel

    /// Settings → Apple Pencil → Squeeze action:
    ///   • `.palette` — toggles the radial tool wheel. Fires on
    ///     squeeze release (single trigger per squeeze).
    ///   • `.tool` — switches to the chosen tool **only while held**
    ///     (press-and-hold). Released → restores the previous tool.
    ///
    /// Three-callback wiring keeps the .palette and .tool semantics
    /// from interfering with each other.

    /// Stash for the press-and-hold tool path. `nil` between squeezes.
    private var savedToolBeforeSqueeze: CeciliasNotesTool?

    /// Squeeze BEGIN — fires when the user presses the squeeze sensor.
    /// `.tool` action: snapshot current tool and switch to chosen tool.
    /// `.palette` action: no-op (wheel toggles on release).
    func handlePencilSqueezeBegan() {
        let action = currentSqueezeAction()
        #if DEBUG
        print("[Pencil] squeeze .began action=\(action.rawValue) currentTool=\(selectedTool.identity)")
        #endif
        guard action == .tool else { return }
        let target = currentSqueezeToolChoice().identity
        // If we're already on the target tool, treat as a no-op so
        // the release doesn't pop back to itself.
        guard selectedTool.identity != target else { return }
        savedToolBeforeSqueeze = selectedTool
        // Press-and-hold squeeze owns its own restore state; must NOT
        // touch `lastTool` (the double-tap ping-pong state).
        selectTool(identity: target, tracksLastTool: false)
        HapticManager.shared.toolSwitched()
    }

    /// Squeeze END / CANCEL — fires when the user releases or the
    /// system cancels. `.tool` action: restore the saved tool.
    /// `.palette` action: no-op (wheel toggles on release, not end).
    func handlePencilSqueezeEnded() {
        let action = currentSqueezeAction()
        #if DEBUG
        print("[Pencil] squeeze .ended/.cancelled action=\(action.rawValue) restoring=\(savedToolBeforeSqueeze?.identity.rawValue ?? "nil")")
        #endif
        guard action == .tool, let saved = savedToolBeforeSqueeze else { return }
        // Restoring after squeeze must NOT poison `lastTool`. Otherwise
        // the next double-tap would toggle to the squeeze tool instead
        // of the user's prior pre-squeeze choice.
        selectTool(saved, tracksLastTool: false)
        savedToolBeforeSqueeze = nil
        HapticManager.shared.toolSwitched()
    }

    /// Squeeze RELEASE — `.palette` action toggles the wheel here
    /// (a single fire per squeeze, not on every phase). `.tool`
    /// action ignores release because its work happened in began/ended.
    func handlePencilSqueezeReleased() {
        let action = currentSqueezeAction()
        guard action == .palette else { return }
        if squeezeWheelCentre != nil {
            squeezeWheelCentre = nil
            return
        }
        squeezeWheelCentre = .zero
        HapticManager.shared.contextMenuOpened()
    }

    private func currentSqueezeAction() -> SqueezeAction {
        let raw = UserDefaults.standard.string(forKey: "pencil.squeeze.action") ?? SqueezeAction.palette.rawValue
        return SqueezeAction(rawValue: raw) ?? .palette
    }

    private func currentSqueezeToolChoice() -> SqueezeToolChoice {
        let raw = UserDefaults.standard.string(forKey: "pencil.squeeze.tool") ?? SqueezeToolChoice.eraser.rawValue
        return SqueezeToolChoice(rawValue: raw) ?? .eraser
    }

    func dismissSqueezeWheel() {
        squeezeWheelCentre = nil
    }

    /// Routes a wheel selection. The host also dismisses the wheel.
    func handleWheelSelection(_ item: WheelItem) {
        switch item {
        case .tool(let identity):
            selectTool(identity: identity)
        case .undo:
            canvasView?.undoManager?.undo()
            scheduleAutosave()
        case .redo:
            canvasView?.undoManager?.redo()
            scheduleAutosave()
        case .toggleFocus, .exitFocus:
            toggleFocusMode()
        }
        squeezeWheelCentre = nil
    }

    // MARK: - Tool selection

    /// Switch tool, remembering the previous selection so "switch between two tools"
    /// (Apple Pencil double-tap) can ping-pong. Snapshots the outgoing tool's
    /// associated values to the per-tool persisted store so the next time
    /// the user picks that identity, their last colour/width/opacity is
    /// restored.
    ///
    /// `tracksLastTool: false` is the squeeze press-and-hold escape hatch —
    /// squeeze maintains its own `savedToolBeforeSqueeze` stash and must not
    /// poison `lastTool`, which belongs to the double-tap ping-pong state
    /// machine. If squeeze wrote `lastTool`, releasing the squeeze would
    /// leave `lastTool` pointing at the squeeze tool, so the next double-tap
    /// would toggle to the squeeze tool instead of the user's prior choice.
    func selectTool(_ tool: CeciliasNotesTool, tracksLastTool: Bool = true) {
        if tool.identity != selectedTool.identity {
            // Snapshot the *outgoing* tool before we overwrite selectedTool.
            toolSettings.snapshot(selectedTool)
            toolSettings.save()
            if tracksLastTool {
                lastTool = selectedTool
            }
        }
        selectedTool = tool
        // Remember inking tools as the reopen default. Transient modes
        // (cursor/lasso/text/image/eraser/ruler) are intentionally not
        // recorded — see `resolveInitialTool`.
        if tool.hasColour {
            userDefaults.set(tool.identity.rawValue, forKey: StorageKeys.lastInkingTool)
        }
        resetToolbarTimer()
    }

    /// Switch to a tool by identity — looks up persisted per-tool settings
    /// (`ToolSettingsStore`) and falls back to defaults. This is what the
    /// tool palette should call when the user taps a tool button.
    func selectTool(identity: CeciliasNotesTool.Identity, tracksLastTool: Bool = true) {
        let restored = toolSettings.tool(for: identity, theme: theme)
        selectTool(restored, tracksLastTool: tracksLastTool)
        // Remember this variant as the category's current pick.
        ToolCategoryStore.setLastVariant(identity)
    }

    /// Selects the last-used variant for the given category — what the
    /// palette's category button calls when tapped while inactive.
    func selectCategory(_ category: ToolCategory) {
        selectTool(identity: ToolCategoryStore.lastVariant(for: category))
    }

    /// Persist the current tool's settings — call after any mutation that
    /// changes colour/width/opacity (slider release, palette ± button, etc.).
    private func persistCurrentToolSettings() {
        toolSettings.snapshot(selectedTool)
        toolSettings.save()
    }

    func toggleLastTwoTools() {
        guard let last = lastTool else { return }
        let current = selectedTool
        selectedTool = last
        lastTool     = current
    }

    /// Pencil double-tap "toggle eraser": ping-pongs between the
    /// eraser and whatever tool the user was on before. Each toggle
    /// swaps `selectedTool` ↔ `lastTool` so repeated double-taps
    /// alternate (pen → eraser → pen → eraser …). A manual tool
    /// change via the palette already updates `lastTool` through
    /// `selectTool(_:)`, so toggling after a manual swap returns to
    /// the most-recently-chosen non-eraser tool — not a stale entry.
    /// First-ever toggle with no prior history falls back to the
    /// default pen.
    func toggleEraser() {
        if case .eraser = selectedTool {
            let current = selectedTool
            if let previous = lastTool {
                selectedTool = previous
                lastTool     = current
            } else {
                selectedTool = CeciliasNotesTool.Defaults.pen(theme: theme)
                lastTool     = current
            }
        } else {
            lastTool     = selectedTool
            selectedTool = CeciliasNotesTool.Defaults.eraser
        }
        HapticManager.shared.toolSwitched()
    }

    func cycleEraserMode() {
        guard case .eraser(let mode) = selectedTool else { return }
        selectedTool = .eraser(mode: mode == .pixel ? .wholeStroke : .pixel)
    }

    /// Clears all PencilKit ink on the current page. Registered with the canvas
    /// undoManager so ⌘Z restores the strokes. Does not touch media or text blocks.
    func eraseCurrentPage() {
        guard let canvas = canvasView else { return }
        let previous = canvas.drawing
        guard !previous.strokes.isEmpty else { return }

        canvas.undoManager?.registerUndo(withTarget: canvas) { target in
            target.drawing = previous
        }
        canvas.undoManager?.setActionName("Erase Page")

        canvas.drawing = PKDrawing()
        scheduleAutosave()
    }

    // MARK: - Shape recognition

    /// Called from the canvas coordinator on `canvasViewDidEndUsingTool`.
    /// Schedules a 600 ms recognition pass; the next stroke cancels it.
    func handleStrokeEnded() {
        // Any active "Undo Shape" pill is from the previous stroke and must
        // commit (or get blown away) when the user starts drawing again.
        if pendingShapeUndo != nil { dismissShapePill() }

        // Highlighter-family interception runs first. When the just-
        // committed stroke passes over selectable PDF text, the
        // detection routine replaces the stroke with V6
        // `PageElement(.highlight)` rows (highlight / underline /
        // strikethrough variants) and returns. Non-highlighter tools
        // and strokes over blank space (or pages with no PDF backing
        // element) fall through to the rest of this method unchanged
        // — `attemptHighlighterTextDetection` self-guards on the
        // current page's `.pdfPage` element, so the legacy
        // `notebook.isPDFBacked` gate isn't needed.
        if selectedTool.isHighlighterFamily {
            attemptHighlighterTextDetection()
        }

        guard shapeRecognitionEnabled, canvasView != nil else { return }
        shapeRecognitionTask?.cancel()
        shapeRecognitionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.runShapeRecognition() }
        }
    }

    private func runShapeRecognition() {
        guard let canvas = canvasView,
              let lastStroke = canvas.drawing.strokes.last
        else { return }

        // Vision rasterisation + contour detection runs ~30–80ms — push
        // the heavy lifting onto a background priority Task and only
        // hop back to the main actor for the canvas mutation.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let shape = await ShapeRecognizer.recognize(lastStroke) else { return }
            await MainActor.run { [weak self] in
                self?.applyRecognisedShape(shape, replacing: lastStroke)
            }
        }
    }

    /// Apply a recognised shape back onto the canvas. Runs on the main
    /// actor — kept separate from `runShapeRecognition` so the Vision
    /// path is purely background.
    private func applyRecognisedShape(_ shape: RecognizedShape, replacing originalStroke: PKStroke) {
        guard let canvas = canvasView else { return }
        // The user may have drawn another stroke (or undone) between
        // background detection and now. Locate the original stroke by
        // identity — we still hold a reference. If it's no longer the
        // last stroke, abandon the replacement rather than mutating
        // something we don't own.
        let strokes = canvas.drawing.strokes
        guard let lastStroke = strokes.last,
              lastStroke.path.creationDate == originalStroke.path.creationDate
        else { return }

        let replacementIndex = strokes.count - 1
        let cleanStroke = makeCleanStroke(for: shape, like: lastStroke)
        var newStrokes = strokes
        newStrokes[replacementIndex] = cleanStroke
        canvas.drawing = PKDrawing(strokes: newStrokes)

        // ⌘Z restores the rough stroke as a separate undo entry.
        canvas.undoManager?.registerUndo(withTarget: canvas) { target in
            var s = target.drawing.strokes
            if replacementIndex < s.count {
                s[replacementIndex] = lastStroke
                target.drawing = PKDrawing(strokes: s)
            }
        }
        canvas.undoManager?.setActionName("Recognise Shape")

        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) {
            pendingShapeUndo = PendingShapeReplacement(
                originalStroke: lastStroke,
                replacementStrokeIndex: replacementIndex
            )
        }

        // Auto-dismiss the pill after 5 s. Bumped from 3 s along with the
        // 0.75 → 0.65 confidence drop: more shapes get caught, so the user
        // needs a slightly longer window to reject a misfire.
        shapePillDismissTask?.cancel()
        shapePillDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) {
                    self?.pendingShapeUndo = nil
                }
            }
        }

        HapticManager.shared.toolSwitched()  // brief tactile signal
        scheduleAutosave()
    }

    /// Tap-handler for the "Undo Shape" pill. Restores the rough stroke
    /// and clears pill state.
    func undoShapeReplacement() {
        guard let pending = pendingShapeUndo,
              let canvas  = canvasView else { return }
        var strokes = canvas.drawing.strokes
        if pending.replacementStrokeIndex < strokes.count {
            strokes[pending.replacementStrokeIndex] = pending.originalStroke
            canvas.drawing = PKDrawing(strokes: strokes)
        }
        dismissShapePill()
        scheduleAutosave()
    }

    private func dismissShapePill() {
        shapePillDismissTask?.cancel()
        shapePillDismissTask = nil
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.fade)) {
            pendingShapeUndo = nil
        }
    }

    /// Build a clean PKStroke for a recognised shape, copying the inking
    /// configuration (colour, width) from the rough stroke that triggered
    /// the recognition.
    private func makeCleanStroke(for shape: RecognizedShape, like template: PKStroke) -> PKStroke {
        let path = pkPath(for: shape, sampleWidth: template.path.first?.size.width ?? 4)
        return PKStroke(ink: template.ink, path: path)
    }

    private func pkPath(for shape: RecognizedShape, sampleWidth: CGFloat) -> PKStrokePath {
        let now = Date()
        var points: [PKStrokePoint] = []
        func addPoint(_ p: CGPoint, t: TimeInterval) {
            points.append(PKStrokePoint(
                location: p,
                timeOffset: t,
                size: CGSize(width: sampleWidth, height: sampleWidth),
                opacity: 1,
                force: 0.5,
                azimuth: 0,
                altitude: .pi / 2
            ))
        }

        // Helper: trace a closed polygon by its vertex list.
        func tracePolygon(_ verts: [CGPoint]) {
            for (i, p) in verts.enumerated() { addPoint(p, t: Double(i) * 0.05) }
            if let first = verts.first { addPoint(first, t: Double(verts.count) * 0.05) }
        }

        // Helper: trace a parametric curve (ellipse / circle).
        func traceEllipse(rect: CGRect) {
            let cx = rect.midX, cy = rect.midY
            let rx = rect.width  / 2
            let ry = rect.height / 2
            let n = 36
            for i in 0...n {
                let a = CGFloat(i) / CGFloat(n) * 2 * .pi
                addPoint(CGPoint(x: cx + rx * cos(a), y: cy + ry * sin(a)),
                         t: Double(i) * 0.01)
            }
        }

        switch shape {
        case .line(let start, let end):
            addPoint(start, t: 0)
            addPoint(end,   t: 0.05)

        case .ellipse(let rect):
            traceEllipse(rect: rect)

        case .circle(let rect):
            traceEllipse(rect: rect)

        case .rectangle(let rect), .square(let rect):
            tracePolygon([
                CGPoint(x: rect.minX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ])

        case .triangle(let a, let b, let c):
            tracePolygon([a, b, c])

        case .pentagon(let pts), .hexagon(let pts):
            tracePolygon(pts)

        case .arrow(let start, let tip, let leftBarb, let rightBarb):
            // One stroke that draws the body, then both barbs in turn:
            //   start → tip → leftBarb → tip → rightBarb
            // Visiting the tip twice is fine in PKStroke land — the shape
            // reads as a clean arrow when rendered.
            addPoint(start,     t: 0.00)
            addPoint(tip,       t: 0.05)
            addPoint(leftBarb,  t: 0.10)
            addPoint(tip,       t: 0.15)
            addPoint(rightBarb, t: 0.20)
        }
        return PKStrokePath(controlPoints: points, creationDate: now)
    }

    func incrementWidth() {
        guard selectedTool.hasWidth else { return }
        // `.eraser(.pixel)` reports `hasWidth == false` now (the
        // configurable size was retired) so the guard catches it
        // — no separate pixel-eraser branch needed.
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth + 0.5)
        persistCurrentToolSettings()
    }

    func decrementWidth() {
        guard selectedTool.hasWidth else { return }
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth - 0.5)
        persistCurrentToolSettings()
    }

    func setWidth(_ width: CGFloat) {
        selectedTool = selectedTool.withWidth(width)
        persistCurrentToolSettings()
    }

    /// Pixel-eraser tip size in points. Reads from / writes to the
    /// shared UserDefaults key that `CeciliasNotesTool.makePKTool` also
    /// reads, so the slider in the eraser popover and the live PKTool
    /// stay in sync. Clamped to the same range the inking-tool width
    /// slider uses for consistency.
    var pixelEraserWidth: CGFloat {
        get {
            let raw = userDefaults.double(forKey: "ceciliasnotes.eraser.pixelSize")
            return raw > 0 ? CGFloat(raw) : 24
        }
        set {
            let clamped = max(4, min(80, newValue))
            userDefaults.set(Double(clamped), forKey: "ceciliasnotes.eraser.pixelSize")
            // Re-emit the tool so the canvas rebuilds the PKTool with
            // the new width on the next stroke.
            if case .eraser(let mode) = selectedTool, mode == .pixel {
                selectedTool = .eraser(mode: .pixel)
            }
            objectWillChange.send()
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        selectedTool = selectedTool.withOpacity(opacity)
        persistCurrentToolSettings()
    }

    // MARK: - Colour selection

    func selectColour(_ colour: UIColor) {
        selectedTool = selectedTool.withColour(colour)
        persistCurrentToolSettings()
        addRecentColour(colour)
    }

    private func addRecentColour(_ colour: UIColor) {
        let hex = colour.hexString
        var current = recentColours
        current.removeAll { $0.hexString == hex }
        current.insert(colour, at: 0)
        if current.count > 8 { current = Array(current.prefix(8)) }
        recentColours = current
        persistRecentColours()
    }

    // MARK: - Pencil double-tap

    func handlePencilDoubleTap() {
        switch activePencilDoubleTapAction {
        case .switchTool:        toggleLastTwoTools()
        case .toggleEraser:      toggleEraser()
        case .showColorPicker:   isShowingColorPicker = true
        case .doNothing:         break
        }
        resetToolbarTimer()
    }

    // MARK: - Page navigation

    /// Swap the current page in-place. Saves the outgoing page synchronously,
    /// then assigns the incoming drawing. **Does not recreate `PKCanvasView`.**
    /// Navigate to a specific page index. In the continuous-scroll editor
    /// (Item 2) this is a *scroll request* rather than a drawing swap —
    /// every page already has its own PKCanvasView mounted in the warm
    /// band, so there's nothing to swap. Setting `pendingScrollPageIndex`
    /// signals `ContinuousCanvasView` to scroll the viewport to that
    /// page; once the scroll lands, the active-page detector updates
    /// `currentPageIndex` (and the overlays that read `currentPage`).
    ///
    /// Returns `true` if the index was valid and a scroll was requested.
    @discardableResult
    func goToPage(index newIndex: Int) -> Bool {
        guard newIndex >= 0, newIndex < pages.count else { return false }
        guard newIndex != currentPageIndex else { return false }
        // Set the synchronous index immediately so overlays / page strip
        // visually track ahead of the scroll animation. The canvas
        // coordinator will re-confirm the active page when the scroll
        // lands.
        currentPageIndex = newIndex
        refreshCurrentPageTextBlocks()
        pendingScrollPageIndex = newIndex
        return true
    }

    func goToNextPage() {
        if currentPageIndex < pages.count - 1 {
            lastSwapDirection = .forward
            goToPage(index: currentPageIndex + 1)
        } else if autoAddEnabled {
            // At last page + auto-add on: append a page and navigate there.
            lastSwapDirection = .forward
            addPageAfterCurrent()
        }
        // At last page + auto-add off: no-op. The toolbar's → button is
        // disabled in this state (see EditorToolbarView).
    }

/// Appends a new page after the current one, refreshes the pages list,
    /// then navigates to the newly-added page. Triggered by `goToNextPage`
    /// when at the last page and `ceciliasnotes.newpage.autoAdd` is on; also reachable
    /// from the page strip's "Add Page After" context menu.
    func addPageAfterCurrent() {
        guard let _ = try? storage.createPage(
            in: notebook,
            after: currentPage.pageNumber,
            pageSize: globalPageSize,
            backgroundTemplate: globalTemplate
        ) else { return }
        refreshPages()
        goToPage(index: currentPageIndex + 1)
        HapticManager.shared.pageAdded()
    }

    /// Silently append a new page immediately after the page with the
    /// given id. Used by the canvas stroke handler to keep a blank page
    /// ready below the one the user is writing on. Deliberately does
    /// NOT navigate or change `currentPageIndex` — the continuous canvas
    /// stacks every page, so the new page simply mounts below the
    /// current view and the user scrolls into it when they reach it. The
    /// previous behaviour navigated to the new page, yanking the view
    /// away from the content the user was still writing.
    func addPage(afterPageId pageId: UUID) {
        guard let anchor = pages.first(where: { $0.id == pageId }) else { return }
        guard let _ = try? storage.createPage(
            in: notebook,
            after: anchor.pageNumber,
            pageSize: globalPageSize,
            backgroundTemplate: globalTemplate
        ) else { return }
        refreshPages()
    }

    // MARK: - Toolbar state hooks

    /// True iff `currentPageIndex` is the last page in the notebook.
    var isOnLastPage: Bool { currentPageIndex == pages.count - 1 }

    /// Per-notebook auto-add flag, persisted via `AutoAddPagesStore`.
    /// Default is `true` — most users want infinite scroll. The
    /// customise panel exposes a toggle to flip this per notebook.
    var autoAddEnabled: Bool { notebook.autoAddPagesOnScroll }

    /// Page size used when appending a new page mid-notebook. The
    /// global Settings → New Pages section was removed; new pages now
    /// follow the notebook's own page size.
    private var globalPageSize: PageSize { notebook.pageSize }

    /// Template used when appending a new page mid-notebook. Mirrors
    /// `globalPageSize` — follows the notebook's own template.
    private var globalTemplate: PageTemplate { notebook.defaultTemplate }

    func goToPreviousPage() {
        guard currentPageIndex > 0 else { return }
        lastSwapDirection = .backward
        goToPage(index: currentPageIndex - 1)
    }

    /// Insert a page after `pageNumber` (or at the end if nil) and
    /// navigate to it. Powers the page-strip "+ add page" button and
    /// the context-menu "Add Page After" item.
    func addPage(after pageNumber: Int? = nil) {
        let target = pageNumber ?? pages.last?.pageNumber
        guard (try? storage.createPage(
            in: notebook,
            after: target,
            pageSize: globalPageSize,
            backgroundTemplate: globalTemplate
        )) != nil else { return }
        refreshPages()
        // Navigate to the freshly-inserted page. After `createPage`
        // renumbers, the new page sits at `(target ?? lastNumber) + 1`
        // i.e. `target` index + 1 (zero-based) → `target` index in 0
        // when target was nil it's appended at the end.
        let newIndex: Int
        if let target {
            newIndex = min(target, pages.count - 1)   // pageNumber is 1-based; index = number
        } else {
            newIndex = pages.count - 1
        }
        goToPage(index: newIndex)
        HapticManager.shared.pageAdded()
    }

    /// Insert a page BEFORE `pageNumber` and navigate to it. Powers
    /// the page-strip context-menu "Insert Page Before" item.
    func addPage(before pageNumber: Int) {
        // `createPage(after:)` with `pageNumber - 1` puts the new page
        // at position `pageNumber`, which after renumbering pushes the
        // original page (and everything after it) down by one.
        let after: Int? = pageNumber > 1 ? pageNumber - 1 : nil
        guard (try? storage.createPage(
            in: notebook,
            after: after,
            pageSize: globalPageSize,
            backgroundTemplate: globalTemplate
        )) != nil else { return }
        refreshPages()
        // The new page is now at the index that the original occupied.
        let newIndex = max(0, min(pageNumber - 1, pages.count - 1))
        goToPage(index: newIndex)
        HapticManager.shared.pageAdded()
    }

    func deletePage(_ page: Page) {
        guard pages.count > 1 else { return }   // don't allow deleting the last page
        HapticManager.shared.pageDeleted()
        let wasCurrent = page.id == currentPage.id
        try? storage.deletePage(page)
        refreshPages()
        if wasCurrent {
            let safeIndex = max(0, min(currentPageIndex, pages.count - 1))
            currentPageIndex = safeIndex
            // Force a drawing reload (Step 8: read via the V6
            // stroke singleton through the storage helper).
            if let canvasView,
               let data    = storage.strokeData(for: pages[safeIndex]),
               let drawing = try? PKDrawing(data: data) {
                canvasView.drawing = drawing
            } else {
                canvasView?.drawing = PKDrawing()
            }
        }
    }

    func duplicatePage(_ page: Page) {
        guard let _ = try? storage.duplicatePage(page) else { return }
        refreshPages()
    }

    /// Move `page` to a new 1-based position in its notebook,
    /// renumbering the rows between source and target. Used by the
    /// page-strip's "Move Left / Move Right" context menu actions.
    /// Out-of-range targets are clamped to the current page count.
    func movePage(_ page: Page, to targetPageNumber: Int) {
        let clamped = max(1, min(pages.count, targetPageNumber))
        guard clamped != page.pageNumber else { return }
        let movedId = page.id
        try? storage.movePage(page, to: clamped)
        refreshPages()
        // Keep the user looking at the page they just moved — the
        // currentPageIndex is index-based, so it would otherwise
        // stay anchored to whichever page slid into the old slot.
        if let newIndex = pages.firstIndex(where: { $0.id == movedId }) {
            currentPageIndex = newIndex
        }
    }

    func refreshPages() {
        let fetched = storage.fetchPages(in: notebook)
        guard !fetched.isEmpty else { return }
        pages = Self.dedupedById(fetched)
        currentPageIndex = max(0, min(currentPageIndex, pages.count - 1))
        refreshCurrentPageTextBlocks()
    }

    /// First-wins dedupe by id. Same shape as
    /// `LibraryViewModel.dedupedById` — kept local rather than
    /// extracted into a shared helper so this fragile-class
    /// defensive code is visible at each consumer site.
    static func dedupedById<T: Identifiable>(_ items: [T]) -> [T] where T.ID: Hashable {
        var seen: Set<T.ID> = []
        var out: [T] = []
        out.reserveCapacity(items.count)
        for item in items where seen.insert(item.id).inserted {
            out.append(item)
        }
        return out
    }

    func refreshCurrentPageTextBlocks() {
        currentPageTextBlocks = (currentPage.textBlocks ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }
    }

    // Step 5: `refreshCurrentPageAudioAnnotations` removed.
    // `AudioElementsOverlayView` reads V6 `PageElement(.audio)`
    // rows directly via SwiftData; the page-state cache the legacy
    // overlay needed no longer exists.

    // MARK: - Sticky notes
    //
    // Step 7: sticky-note CRUD moved off the view-model. The
    // per-page `StickyNoteElementsOverlayView` owns creation,
    // edit, recolour, and soft-delete via `StickyNoteCommit` +
    // SwiftData `@Bindable` propagation. The only sticky-related
    // state the view-model still owns is `editingStickyNoteId`
    // (mirrored from the overlay so the state machine can enter
    // `.stickyNoteEditing(_:)`).

    // MARK: - Lecture mode

    /// Mic-button menu → "Lecture". Spins up a fresh
    /// `LectureRecorder`, publishes it so the editor view swaps to
    /// `LectureRecordingView`, and kicks off recording. Failures
    /// (mic denied, engine couldn't start) clear the recorder
    /// silently — the user is back to the editor with no recording.
    // MARK: - Recording entry (Step 6)

    /// Voice Note: start an inline pulsing audio strip on the
    /// current page. Routes through `RecordingSession.shared`.
    func startVoiceNoteRecording() async {
        let pageSize = currentPage.pageSize.pointSize
        await RecordingSession.shared.startVoiceNote(
            on: currentPage.id,
            notebookId: notebook.id,
            pageSize: pageSize
        )
    }

    /// Dictation: create a new page, seed an empty transcript
    /// TextContent at its top, and start the live-transcription
    /// recorder. `RecordingSession` owns the state; we provide the
    /// page-creation + navigation closures because they need
    /// view-model state (currentPage.pageNumber, currentPageIndex).
    func startDictationRecording() async {
        let notebookId = notebook.id
        let pageSize = currentPage.pageSize.pointSize
        let fromPageId = currentPage.id
        #if DEBUG
        print("[Dictation] startDictationRecording — notebookId=\(notebookId) fromPageId=\(fromPageId) pageSize=\(pageSize)")
        #endif
        await RecordingSession.shared.startDictation(
            notebookId: notebookId,
            fromPageId: fromPageId,
            pageSize: pageSize,
            createNewPage: { [storage, notebook, currentPage] in
                try? storage.createPage(
                    in: notebook,
                    after: currentPage.pageNumber,
                    pageSize: notebook.pageSize,
                    backgroundTemplate: notebook.defaultTemplate
                )
            },
            navigateToPage: { [weak self] newPageId in
                guard let self else { return }
                // `startDictation` invokes this closure synchronously
                // after an `await` resume, so its `@Published`
                // mutations (`refreshPages()`, `currentPageIndex`,
                // `pendingScrollPageIndex`) can land inside a SwiftUI
                // view-update pass — the source of several of the
                // "Publishing changes from within view updates"
                // warnings logged on dictation start. Hopping one
                // runloop tick moves the whole navigation cluster
                // out of the update pass. Safe to defer: nothing in
                // the dictation state machine depends on the page
                // index (only on `RecordingSession.state`, which is
                // NOT deferred).
                Task { @MainActor in
                    self.refreshPages()
                    if let idx = self.pages.firstIndex(where: { $0.id == newPageId }) {
                        self.currentPageIndex = idx
                        self.pendingScrollPageIndex = idx
                        #if DEBUG
                        print("[Dictation] navigateToPage — newPageId=\(newPageId) idx=\(idx) currentPage.id now=\(self.currentPage.id)")
                        #endif
                    } else {
                        #if DEBUG
                        print("[Dictation] navigateToPage — newPageId=\(newPageId) NOT FOUND in refreshed pages")
                        #endif
                    }
                }
            }
        )
    }

    // MARK: - Overlay-view StorageService wrappers
    //
    // The TextBlockOverlay, AudioAnnotationPinsOverlay, and Media overlay all
    // used to call `StorageService.shared` directly. These wrappers route the
    // mutations through the view model so views never depend on StorageService.

    /// Returns the created `TextBlock` so the overlay can install its layout
    /// state immediately. Refreshes `currentPageTextBlocks` and schedules
    /// autosave on success. Convenience for the active-page case; per-page
    /// overlays should use `createTextBlock(onPageId:at:)`.
    @discardableResult
    func createTextBlock(at normalizedRect: CGRect) -> TextBlock? {
        createTextBlock(onPageId: currentPage.id, at: normalizedRect)
    }

    /// Per-page text-block creation. The text-block overlay is mounted
    /// per-page (Phase 3b), so the overlay knows its own pageId without
    /// going through `currentPage`.
    @discardableResult
    func createTextBlock(onPageId pageId: UUID, at normalizedRect: CGRect) -> TextBlock? {
        guard let page = pages.first(where: { $0.id == pageId }) else { return nil }
        guard let block = try? storage.createTextBlock(on: page, at: normalizedRect) else {
            return nil
        }
        if pageId == currentPage.id { refreshCurrentPageTextBlocks() }
        scheduleAutosave()
        return block
    }

    func updateTextBlock(_ block: TextBlock,
                         richText: NSAttributedString,
                         rect: CGRect?) {
        try? storage.updateTextBlock(block, richText: richText, rect: rect)
        // No refresh — TextBlock's @Model mutation propagates through SwiftData.
        scheduleAutosave()
    }

    func deleteTextBlock(_ block: TextBlock) {
        try? storage.deleteTextBlock(block)
        refreshCurrentPageTextBlocks()
        scheduleAutosave()
    }

    /// Inserts an audio file (already copied into
    /// `MediaStorage.url(for: .audio, id:)`) into the current page
    /// as a V6 `PageElement(.audio) + AudioContent`. Used by
    /// `AudioFilePicker` after the file is staged on disk.
    /// Step 5 replaced the legacy `AudioRecord` insert path with
    /// this helper that funnels through `AudioElementCommit`.
    func insertAudioFile(recordId: UUID, duration: Double) {
        let pageSize = currentPage.pageSize.pointSize
        AudioElementCommit.commit(
            contentId: recordId,
            pageId: currentPage.id,
            notebookId: notebook.id,
            pageSize: pageSize,
            durationSeconds: duration
        )
        scheduleAutosave()
    }

    // MARK: - Audio recording

    func startRecording() async {
        #if DEBUG
        print("[Audio] 0. EditorViewModel.startRecording() (quick-record path — AudioRecorder, NOT LectureRecorder)")
        #endif
        do {
            try await audioRecorder.requestPermission()
            #if DEBUG
            print("[Audio] 0a. mic permission granted")
            #endif
            // New audio writes land in the unified `MediaStorage.audio/`
            // tree directly. The legacy `audioDirURL(notebookId:)`
            // location is read-only after Phase 3 — only used by the
            // launch migration to find pre-existing files. See
            // `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.B.
            MediaStorage.ensureDirectoriesExist()
            let tempId  = UUID()
            let fileURL = MediaStorage.url(for: .audio, id: tempId)
            try await audioRecorder.start(outputURL: fileURL)
            recordingState = .recording
            pendingRecordingURL = fileURL
            pendingRecordingId  = tempId
        } catch {
            #if DEBUG
            print("[Audio] 0x. startRecording threw: \(error.localizedDescription)")
            #endif
            mediaError = AppError.humanize(error)
        }
    }

    func stopRecording() async {
        #if DEBUG
        print("[Audio] stopRecording entry state=\(recordingState)")
        #endif
        guard recordingState == .recording else { return }
        recordingState = .processing
        do {
            let result = try await audioRecorder.stop()
            #if DEBUG
            print("[Audio] stopRecording audioRecorder.stop returned duration=\(result.duration)s bytes=\(result.fileSizeBytes)")
            #endif
            guard let url = pendingRecordingURL, let id = pendingRecordingId else {
                recordingState = .idle
                return
            }

            // Read both toggles fresh at stop-time so Settings changes
            // apply immediately. The per-recording `isTranscriptionEnabled`
            // override (the panel's "Transcribe" switch) gates further;
            // the master "Save audio clips" toggle has no per-recording
            // override since it's an always-on default.
            let saveAudio  = UserDefaults.standard.object(forKey: "ceciliasnotes.audio.saveClips") as? Bool ?? true
            let transcribe = isTranscriptionEnabled

            // Both off — nothing to keep. Discard the temp file and
            // dismiss; the panel already showed the "both off" hint.
            guard saveAudio || transcribe else {
                try? FileManager.default.removeItem(at: url)
                pendingRecordingURL = nil
                pendingRecordingId  = nil
                recordingState      = .idle
                return
            }

            if saveAudio {
                // Step 5: short-note recordings commit through the
                // shared `AudioElementCommit` helper now — same path
                // as the lecture flow. Pin position is owned by the
                // commit helper (top-left default); future selection
                // chrome lets the user move it.
                let pageSize = currentPage.pageSize.pointSize
                AudioElementCommit.commit(
                    contentId: id,
                    pageId: currentPage.id,
                    notebookId: notebook.id,
                    pageSize: pageSize,
                    durationSeconds: result.duration
                )
                pendingRecordingURL = nil
                pendingRecordingId  = nil
                recordingState      = .idle

                if transcribe {
                    let capturedURL = url
                    let capturedId  = id
                    Task.detached(priority: .utility) {
                        await SpeechTranscriber.shared.transcribe(
                            url: capturedURL,
                            annotationId: capturedId
                        )
                    }
                }
            } else {
                // Transcript-only path: run the recogniser over the
                // temp file, save the text as a standalone TextBlock,
                // then delete the audio file. No `AudioAnnotation`
                // exists to hang the transcript on.
                let capturedURL = url
                let capturedPage = currentPage
                pendingRecordingURL = nil
                pendingRecordingId  = nil
                recordingState      = .idle

                Task(priority: .utility) { [weak self] in
                    let result = await SpeechTranscriber.shared.transcribeFile(url: capturedURL)
                    try? FileManager.default.removeItem(at: capturedURL)
                    guard let text = result?.text, !text.isEmpty else { return }
                    _ = try? StorageService.shared.createTextBlock(on: capturedPage, content: text)
                    self?.refreshCurrentPageTextBlocks()
                }
            }
        } catch {
            mediaError     = AppError.humanize(error)
            recordingState = .idle
        }
    }

    /// Returns the AudioRecorder's live level stream for the waveform view.
    func audioLevelStream() async -> AsyncStream<Float> {
        audioRecorder.levelStream ?? AsyncStream { $0.finish() }
    }

    private var pendingRecordingURL: URL?
    private var pendingRecordingId:  UUID?

    // MARK: - Title rename

    func renameNotebook(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != notebook.title else { return }
        do {
            try storage.updateNotebook(notebook, title: trimmed,
                                       coverColorHex: nil, isPinned: nil, tags: nil)
            // Defer to next runloop — synchronous `objectWillChange.send`
            // inside a view-body-driven mutation creates AttributeGraph
            // cycles. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` Reg 1.
            Task { @MainActor in self.objectWillChange.send() }
        } catch {
            showError(.storageFailed(action: "rename notebook", underlying: error))
        }
    }

    // MARK: AI — title / tag suggestions

    /// Generate a 2–5 word title suggestion if the conditions match:
    /// AI is on, title is a placeholder, the notebook has enough
    /// content, and we haven't already suggested once this session.
    func maybeGenerateTitleSuggestion() {
        guard IntelligenceService.shared.canRun else { return }
        guard titleLooksLikePlaceholder else { return }
        guard !hasGeneratedTitleSuggestion else { return }
        hasGeneratedTitleSuggestion = true
        let id = notebook.id
        Task { @MainActor [weak self] in
            let text = SearchIndexService.shared.combinedText(for: id)
            let proposed = await IntelligenceService.shared.suggestTitle(from: text)
            guard let proposed,
                  let self,
                  self.notebook.id == id,
                  self.titleLooksLikePlaceholder
            else { return }
            self.suggestedTitle = proposed
        }
    }

    /// Apply the proposed title and dismiss the pill.
    func applySuggestedTitle() {
        guard let proposed = suggestedTitle else { return }
        renameNotebook(proposed)
        suggestedTitle = nil
    }

    func dismissSuggestedTitle() {
        suggestedTitle = nil
    }

    // MARK: AI — suggested tags

    @Published private(set) var suggestedTags: [String] = []
    private var hasGeneratedTagSuggestion = false

    /// Generate 1–3 tag suggestions when the notebook has enough
    /// content (>50 words) and the user hasn't already dismissed
    /// the banner for this notebook. Tags that already exist on the
    /// notebook are filtered out before surfacing.
    func maybeGenerateTagSuggestions() {
        guard IntelligenceService.shared.canRun else { return }
        guard !hasGeneratedTagSuggestion else { return }
        guard !IntelligenceCache.tagsDismissed(for: notebook.id) else { return }
        // Already has tags — no suggestion needed.
        guard notebook.tags.isEmpty else { return }
        hasGeneratedTagSuggestion = true

        let id = notebook.id
        Task { @MainActor [weak self] in
            let text = SearchIndexService.shared.combinedText(for: id)
            let raw = await IntelligenceService.shared.suggestTags(from: text)
            // Defence-in-depth: even though IntelligenceService
            // pre-normalises, run each through the project's
            // canonical TagValidator so we never end up with
            // invalid tags (emoji, digits, over-length) downstream.
            let existing = self?.notebook.tags ?? []
            var validated: [String] = []
            for candidate in raw {
                if case .success(let normal) = TagValidator.validate(
                    candidate, against: existing + validated
                ) {
                    validated.append(normal)
                }
            }
            guard let self, self.notebook.id == id, !validated.isEmpty
            else { return }
            self.suggestedTags = validated
        }
    }

    func applyAllSuggestedTags() {
        guard !suggestedTags.isEmpty else { return }
        var updated = notebook.tags
        for tag in suggestedTags where !updated.contains(tag) {
            updated.append(tag)
        }
        notebook.tags = updated
        persistTags()
        suggestedTags = []
    }

    func dismissSuggestedTags() {
        IntelligenceCache.markTagsDismissed(for: notebook.id)
        suggestedTags = []
    }

    /// Persist the notebook's current `tags` array via the standard
    /// updateNotebook path. The Customise panel mutates `tags`
    /// directly on the model (cheap), then asks the view-model to
    /// flush — SwiftData is the source of truth for full-text
    /// search, library filtering, and the grid cards.
    func persistTags() {
        do {
            try storage.updateNotebook(
                notebook,
                title:         nil,
                coverColorHex: nil,
                isPinned:      nil,
                tags:          notebook.tags
            )
            // Defer to next runloop — synchronous `objectWillChange.send`
            // inside a view-body-driven mutation creates AttributeGraph
            // cycles. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` Reg 1.
            Task { @MainActor in self.objectWillChange.send() }
        } catch {
            showError(.storageFailed(action: "update tags", underlying: error))
        }
    }

    // MARK: - Customise panel mutations (Item 1)
    //
    // Each method updates the notebook live, persists the user's choice as
    // the new "last-used" default for future quick-creates, and bumps
    // `objectWillChange` so views re-read the updated `notebook.*` fields.
    // No save/cancel — direct manipulation.

    /// Apply a cover preset. Updates the notebook's color+texture and
    /// remembers the choice for future quick-creates.
    func applyCustomCover(_ cover: NotebookCover) {
        do {
            try storage.updateNotebook(
                notebook,
                title:         nil,
                coverColorHex: cover.colorHex,
                isPinned:      nil,
                tags:          nil,
                coverTexture:  cover.texture
            )
            userDefaults.set(cover.rawValue, forKey: "ceciliasnotes.lastUsed.cover")
            // Defer to next runloop — synchronous `objectWillChange.send`
            // inside a view-body-driven mutation creates AttributeGraph
            // cycles. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` Reg 1.
            Task { @MainActor in self.objectWillChange.send() }
        } catch {
            showError(.storageFailed(action: "update cover", underlying: error))
        }
    }

    /// Apply a page size. Mutates the notebook's default page size, plus
    /// the *first page* if it is empty (no strokes) — so a freshly-created
    /// notebook visibly resizes behind the panel. Pages with content are
    /// left alone to avoid clipping the user's drawing.
    func applyCustomPageSize(_ size: PageSize) {
        do {
            try storage.updateNotebook(
                notebook,
                title:         nil,
                coverColorHex: nil,
                isPinned:      nil,
                tags:          nil,
                pageSize:      size
            )
            // Apply to the first page only when empty — preserves drawings
            // on existing notebooks where the user re-enters the panel.
            // Step 8: "empty" now means no V6 stroke singleton or an
            // empty one.
            if let first = (notebook.pages ?? []).first(where: { $0.pageNumber == 1 && !$0.isDeleted }),
               (storage.strokeData(for: first)?.isEmpty ?? true) {
                first.pageSize  = size
                first.updatedAt = Date()
            }
            userDefaults.set(size.rawValue, forKey: "ceciliasnotes.lastUsed.pageSize")
            // Defer to next runloop — synchronous `objectWillChange.send`
            // inside a view-body-driven mutation creates AttributeGraph
            // cycles. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` Reg 1.
            Task { @MainActor in self.objectWillChange.send() }
        } catch {
            showError(.storageFailed(action: "update page size", underlying: error))
        }
    }

    /// Apply a page template. Forward-only: only pages added after
    /// this call inherit the new template. Existing pages — including
    /// page 1 — keep whatever template they were created with, so the
    /// user can mix templates within a notebook by changing the
    /// default before adding each new page.
    func applyCustomTemplate(_ template: PageTemplate) {
        do {
            try storage.updateNotebook(
                notebook,
                title:           nil,
                coverColorHex:   nil,
                isPinned:        nil,
                tags:            nil,
                defaultTemplate: template
            )
            userDefaults.set(template.jsonString, forKey: "ceciliasnotes.lastUsed.template")
            // Defer to next runloop — synchronous `objectWillChange.send`
            // inside a view-body-driven mutation creates AttributeGraph
            // cycles. See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` Reg 1.
            Task { @MainActor in self.objectWillChange.send() }
        } catch {
            showError(.storageFailed(action: "update template", underlying: error))
        }
    }

    // MARK: - Autosave (debounced 1.2s)

    /// Called by the canvas coordinator on `canvasViewDrawingDidChange`.
    /// Cancels any pending save and schedules a new one 1.2s later.
    func scheduleAutosave() {
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self else { return }
            await self.performSave()
        }
    }

    /// Force-flush any pending save synchronously. Used when navigating between pages.
    func flushPendingSaveSync() {
        if isDirty, let canvasView {
            let drawing = canvasView.drawing
            let page    = currentPage
            savePage(page, drawing: drawing)
            isDirty = false
        }
        // ContinuousCanvasView (Item 2) owns per-page autosave for *every*
        // page in the warm band, not just the active one. Give it a chance
        // to flush all dirty pages before the editor unwinds.
        canvasFlushAllHandler?()
    }

    /// Synchronous per-page save. Used by ContinuousCanvasView's coordinator
    /// for every page's debounced autosave AND for the unmount/dismiss
    /// flush. Idempotent — calling it on a page that's already up-to-date
    /// just rewrites the same bytes.
    func savePage(_ page: Page, drawing: PKDrawing) {
        do {
            try storage.updatePageStrokes(page, drawing: drawing)
            saveStatus = .saved
            scheduleSavedFlash()
            // Phase 4E: thumbnail cache is keyed by
            // `(pageId, strokeFingerprint, pdfFingerprint)`. A new
            // stroke produces a new fingerprint, so the next lookup
            // automatically misses and the row re-renders via the
            // composite path. No manual invalidate needed.
            // Re-OCR the page for full-text search. Debounced by 2s
            // inside `SearchIndexService.scheduleOCR` — bursts of
            // stroke saves coalesce into one Vision pass per page.
            SearchIndexService.shared.scheduleOCR(
                notebookId: page.notebookId,
                pageId:     page.id
            )
            IntelligenceService.shared.scheduleSummary(notebookId: page.notebookId)
            maybeGenerateTitleSuggestion()
            maybeGenerateTagSuggestions()
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    /// Set by the active canvas host (ContinuousCanvasView's coordinator)
    /// so `flushPendingSaveSync()` can walk every dirty page on dismiss.
    var canvasFlushAllHandler: (() -> Void)?

    /// Set by the page-strip / keyboard so the continuous canvas knows to
    /// scroll to a particular page index. Read-and-clear contract: the
    /// canvas coordinator clears the value once it has acted on it.
    @Published var pendingScrollPageIndex: Int?

    private func performSave() async {
        guard let canvasView else { return }
        let drawing = canvasView.drawing
        let page    = currentPage

        saveStatus = .saving

        do {
            try storage.updatePageStrokes(page, drawing: drawing)
            isDirty    = false
            saveStatus = .saved
            scheduleSavedFlash()
            // Composite-path regeneration via the page-strip row's
            // `.onChange(of: page.updatedAt)` observer — see the
            // identical comment in `savePage(_:drawing:)`.
            SearchIndexService.shared.scheduleOCR(
                notebookId: page.notebookId,
                pageId:     page.id
            )
            IntelligenceService.shared.scheduleSummary(notebookId: page.notebookId)
            maybeGenerateTitleSuggestion()
            maybeGenerateTagSuggestions()
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

    private func scheduleSavedFlash() {
        savedFlashTask?.cancel()
        savedFlashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.0))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if case .saved = self?.saveStatus {
                    self?.saveStatus = .idle
                }
            }
        }
    }

    // The legacy `scheduleThumbnailRegeneration` strokes-only
    // fast path was removed — it raced the composite path in
    // `PageThumbnailCache.generate` and won, leaving a
    // transparent-background image in the cache that read as
    // "blank" for thin/sparse drawings. Thumbnails now flow
    // exclusively through the composite path: `savePage` /
    // `flushPendingSaveSync` invalidate the cache; the page-strip
    // row's `.onChange(of: page.updatedAt)` regenerates via
    // `PageThumbnailCache.generate(for:targetSize:)`.

    // MARK: - Exit

    /// Called when the user taps Back. Triggers a flush save before dismissing.
    func prepareForDismissal() {
        toolbarHideTask?.cancel()
        flushPendingSaveSync()
        // Focus Mode is editor-scoped — exit on the way back to Library so
        // the next notebook opens with normal chrome.
        isFocusMode = false
        // Clear the launch-time resume pointer. Background while
        // inside the editor (the user-facing "resume me here"
        // case) leaves the key in place; pressing Back is the
        // user explicitly saying "I'm done with this notebook,"
        // so the next cold launch should land on library home
        // even though `LaunchRecovery.previousShutdownWasClean`
        // says the prior shutdown was orderly.
        userDefaults.removeObject(forKey: "ceciliasnotes.resume.lastNotebookId")
        userDefaults.removeObject(forKey: "ceciliasnotes.resume.lastPageIndex")
    }
}


// MARK: - UIColor hex string helper

extension UIColor {
    /// Returns "#RRGGBB" — alpha is dropped intentionally (we store opacity separately).
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X",
                      Int(round(r * 255)), Int(round(g * 255)), Int(round(b * 255)))
    }
}

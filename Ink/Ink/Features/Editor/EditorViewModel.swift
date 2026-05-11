import AVFoundation
import Combine
import Foundation
import PencilKit
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

    // MARK: Pencil Pro squeeze radial wheel
    /// Drives the radial wheel overlay. Nil = wheel hidden.
    @Published var squeezeWheelCentre: CGPoint?

    // MARK: Tool state
    @Published var selectedTool: InkTool
    @Published private(set) var lastTool: InkTool?         // for "switch between two tools"
    @Published var activePencilDoubleTapAction: PencilDoubleTapAction = .toggleEraser
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
    /// The previous `@Published var imageImportRequest` that
    /// drove a `.sheet(item:)` inside the editor cover is gone —
    /// the picker is now presented from `LibraryView` via
    /// `ImagePickerBridge` to avoid the nested-presentation
    /// collapse that closed the editor on iPad.
    struct ImageImportRequest: Identifiable {
        let id = UUID()
        let normalizedX: Double
        let normalizedY: Double
    }

    /// Open the import picker centred on the current page. Routes
    /// through `ImagePickerBridge` so the picker is presented at
    /// the library root level, above the editor's
    /// `.fullScreenCover`.
    func requestImageImportCentred() {
        let request = ImageImportRequest(normalizedX: 0.5, normalizedY: 0.5)
        ImagePickerBridge.shared.present { [weak self] image, ext in
            self?.commitImportedImage(image, fileExtension: ext, at: request)
        }
    }

    /// Commit a picked image to disk + the side-channel store. The
    /// file is written under `Documents/media/<notebookId>/`; the
    /// record is sized to ~60% of page width preserving aspect
    /// ratio, positioned so its centre lands on
    /// `(normalizedX, normalizedY)`. Runs the disk write on a
    /// detached task — the architecture rule for file I/O.
    func commitImportedImage(
        _ image: UIImage,
        fileExtension ext: String,
        at request: ImageImportRequest
    ) {
        let attachmentId = UUID()
        let safeExt = ext.isEmpty ? "jpg" : ext.lowercased()
        let fileName = "\(attachmentId.uuidString).\(safeExt)"
        let dir = MediaAttachmentStore.mediaDirectory(for: notebook.id)
        let absoluteURL = dir.appendingPathComponent(fileName)

        // Resolve the documents-relative path once — the record
        // stores the relative form so a sandbox relocate doesn't
        // invalidate the reference.
        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0].path
        let relativePath: String
        if absoluteURL.path.hasPrefix(docs) {
            relativePath = String(
                absoluteURL.path
                    .dropFirst(docs.count)
                    .drop(while: { $0 == "/" })
            )
        } else {
            // Fallback — should never happen given the directory
            // above is in Documents, but the safe branch keeps the
            // record valid even if the constant changes.
            relativePath = "media/\(notebook.id.uuidString)/\(fileName)"
        }

        // Encode + write off the main actor.
        Task.detached(priority: .userInitiated) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let data: Data?
            switch safeExt {
            case "png":  data = image.pngData()
            default:     data = image.jpegData(compressionQuality: 0.85)
            }
            guard let data else { return }
            try? data.write(to: absoluteURL, options: .atomic)
        }

        // Aspect-preserving fit to ~60% of page width. Falls back
        // to a 60×40 box when the image has zero dimensions
        // (shouldn't happen — UIImagePickerController and
        // PHPickerViewController guarantee non-zero).
        let pixelWidth  = max(1, image.size.width)
        let pixelHeight = max(1, image.size.height)
        let aspect = pixelHeight / pixelWidth
        let targetW: Double = 0.6
        let targetH: Double = Double(aspect) * targetW

        let record = MediaAttachmentRecord(
            id: attachmentId,
            pageId: currentPage.id,
            notebookId: notebook.id,
            relativeFilePath: relativePath,
            normalizedX: max(0, min(1 - targetW, request.normalizedX - targetW / 2)),
            normalizedY: max(0, min(1 - targetH, request.normalizedY - targetH / 2)),
            normalizedWidth:  targetW,
            normalizedHeight: targetH,
            rotationDegrees: 0,
            originalWidth: Double(pixelWidth),
            originalHeight: Double(pixelHeight),
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )
        MediaAttachmentStore.save(record)
    }

    /// Annotation pulse signal. Set to a `PDFTextAnnotationRecord.id`
    /// or `StickyNoteRecord.id` to make that mark pulse once on the
    /// canvas (scale 1.0 → 1.1 → 1.0 over 0.3s). The annotation list
    /// sheet's row tap drives this after the page-scroll settles.
    /// `PageRenderer` (Combine-subscribed via `attachPulseSource`) and
    /// `StickyNoteMarker` (SwiftUI `@ObservedObject`) both read this
    /// — single source of truth for both surfaces.
    @Published var pulsingAnnotationId: UUID?

    /// PDF annotation writer for the current notebook session, or
    /// `nil` when the notebook isn't PDF-backed. Instantiated lazily
    /// the first time it's read so non-PDF notebooks pay zero cost.
    /// The writer mirrors the in-app `PDFTextAnnotationStore` into
    /// the source PDF on disk via a debounced detached task.
    lazy var pdfAnnotationWriter: PDFAnnotationWriter? = {
        guard notebook.isPDFBacked,
              let url = notebook.sourcePDFURL
        else { return nil }
        return PDFAnnotationWriter(notebookId: notebook.id, sourceURL: url)
    }()

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

    /// Called from `EditorView.onAppear`. Shows the pill iff the notebook
    /// was created within the last 30 seconds AND we haven't already shown
    /// the pill for it this session. The 5-second auto-dismiss is owned
    /// by the pill view itself (it has the timing context).
    func markCustomisePillIfFresh() {
        guard !Self.pillShownIds.contains(notebook.id) else { return }
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
    @Published private(set) var currentPageAttachments: [MediaAttachment] = []
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

    /// Drives the media picker sheet — set by MediaInsertCoordinator methods.
    @Published var activeMediaSource: MediaSource?

    // MARK: Media insert coordinator (lazy to break init cycle)
    lazy var mediaInsertCoordinator: MediaInsertCoordinator = MediaInsertCoordinator(viewModel: self)

    // MARK: Undo stack for deleted attachments (session-only, not SwiftData undo)
    private var deletedAttachmentsUndo: [(MediaAttachment, Data?)] = []

    // MARK: Audio annotations
    @Published private(set) var currentPageAudioAnnotations: [AudioAnnotation] = []

    // MARK: Sticky notes
    //
    // Side-channel storage (`StickyNoteStore`) keeps the V3 schema
    // unchanged. The overlay reads `currentPageStickyNotes` and
    // re-renders whenever this view-model bumps the array — which
    // happens after every add / edit / delete via `refreshCurrentPageStickyNotes`.

    @Published private(set) var currentPageStickyNotes: [StickyNoteRecord] = []

    // MARK: Lecture mode (Pass A)
    //
    // When `activeLectureRecorder` is non-nil the editor view swaps
    // its body for `LectureRecordingView`. Stop returns the saved
    // record so the editor can drop the post-stop placeholder
    // TextBlock on the page.

    @Published var activeLectureRecorder: LectureRecorder?
    /// When non-nil, the SwiftUI popover for this sticky note is open
    /// and the body field is focused.
    @Published var editingStickyNoteId: UUID?

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
    @Published var playingAnnotationId:         UUID?     = nil
    @Published var isRecordingPanelVisible:     Bool      = false {
        didSet {
            guard oldValue != isRecordingPanelVisible else { return }
            if isRecordingPanelVisible { beginInteraction(.recordingPanel) }
            else                       { endInteraction(.recordingPanel) }
        }
    }
    @Published var recordingState:              RecordingState = .idle
    /// Defaults from `ink.transcription.auto` (Settings → Audio & Transcription).
    /// User can also override per-recording via the panel toggle while recording.
    @Published var isTranscriptionEnabled: Bool =
        UserDefaults.standard.object(forKey: "ink.transcription.auto") as? Bool ?? true
    @Published var isShowingAudioFilePicker:    Bool      = false

    private var audioRecorder = AudioRecorder()

    // MARK: Keyboard offset — updated by EditorView keyboard notifications
    @Published var keyboardVisibleHeight: CGFloat = 0

    // MARK: Pending exit confirmation (back button while dirty)
    @Published var isShowingExitConfirmation: Bool = false

    // MARK: Shape recognition
    /// User toggle, persists across launches. Default OFF.
    @AppStorage("ink.shape.recognitionEnabled") var shapeRecognitionEnabled: Bool = false

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
    private let theme: InkTheme

    // MARK: Init

    init(
        notebook: Notebook,
        // Default `.shared` is nil-resolved inside the body so the
        // `@MainActor`-isolated singleton is touched on the main actor
        // rather than at the call-site (Swift 6 default-value
        // isolation rules).
        storage: StorageService? = nil,
        userDefaults: UserDefaults = .standard,
        theme: InkTheme = .light
    ) {
        self.notebook        = notebook
        let resolvedStorage  = storage ?? .shared
        self.storage         = resolvedStorage
        self.userDefaults    = userDefaults
        self.theme           = theme

        let fetched = resolvedStorage.fetchPages(in: notebook)
        // SwiftData should always return at least one page (createNotebook seeds one),
        // but guard for safety.
        self.pages            = fetched.isEmpty ? [] : fetched

        // Restore the last viewed page if the resume feature is on AND the page
        // is still in range. The check happens once at init; subsequent changes
        // are written back in `currentPageIndex`'s didSet.
        let resumeOn = userDefaults.object(forKey: "ink.resume.enabled") as? Bool ?? true
        let savedIndex = userDefaults.integer(forKey: "ink.resume.lastPageIndex")
        if resumeOn,
           userDefaults.string(forKey: "ink.resume.lastNotebookId") == notebook.id.uuidString,
           savedIndex >= 0, savedIndex < fetched.count {
            self.currentPageIndex = savedIndex
        } else {
            self.currentPageIndex = 0
        }
        // Restore the pen's last-used colour/width/opacity if present.
        self.selectedTool     = ToolSettingsStore.load().tool(for: .pen, theme: theme)

        loadPersistedState(theme: theme)

        // Now that init is done, we can mark this notebook as "currently open" —
        // doing it after init avoids racing the init-time resume check above.
        userDefaults.set(notebook.id.uuidString, forKey: "ink.resume.lastNotebookId")
        userDefaults.set(self.currentPageIndex, forKey: "ink.resume.lastPageIndex")

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
                self.userDefaults.set(index, forKey: "ink.resume.lastPageIndex")
            }
            .store(in: &cancellables)

        resetToolbarTimer()
        refreshCurrentPageTextBlocks()
        refreshCurrentPageAttachments()
        refreshCurrentPageAudioAnnotations()
        refreshCurrentPageStickyNotes()

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
    }

    deinit {
        // Tasks captured [weak self] — they will be no-ops after dealloc.
        toolbarHideTask?.cancel()
        headerManualReHideTask?.cancel()
        saveTask?.cancel()
        savedFlashTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    /// Background-notification handler. `@objc` so it can be
    /// targeted by `NotificationCenter.addObserver(selector:)`.
    @objc private func handleAppBackground() {
        guard let writer = pdfAnnotationWriter else { return }
        Task { @MainActor in
            await writer.flushImmediately()
        }
    }

    /// Editor view should call this on dismiss so any pending
    /// annotation write is flushed before the writer is torn down
    /// with the view model.
    func flushPDFAnnotationsImmediately() async {
        guard let writer = pdfAnnotationWriter else { return }
        await writer.flushImmediately()
    }

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
        static let recentColours       = "ink.colorPicker.recent"
        // Must stay in lock-step with SettingsViewModel.DoubleTapAction's @AppStorage key.
        static let pencilDoubleTap     = "ink.pencil.doubletap"
    }

    private func loadPersistedState(theme: InkTheme) {
        // Recent colours
        if let hexes = userDefaults.array(forKey: StorageKeys.recentColours) as? [String] {
            recentColours = hexes.map { UIColor(hex: $0) }
        }

        // Pencil double-tap action — honour system preference if set
        if let raw = userDefaults.string(forKey: StorageKeys.pencilDoubleTap),
           let action = PencilDoubleTapAction(rawValue: raw) {
            activePencilDoubleTapAction = action
        } else if let mapped = PencilDoubleTapAction.from(UIPencilInteraction.preferredTapAction) {
            activePencilDoubleTapAction = mapped
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
            withAnimation(.inkSpring(InkSpring.fade)) { isToolbarVisible = true }
        }
        toolbarHideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled, let self else { return }
            await MainActor.run {
                withAnimation(.inkSpring(InkSpring.fade)) {
                    self.isToolbarVisible = false
                }
            }
        }
    }

    func keepToolbarVisible() {
        toolbarHideTask?.cancel()
        if !isToolbarVisible {
            withAnimation(.inkSpring(InkSpring.fade)) { isToolbarVisible = true }
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
            withAnimation(.inkSpring(InkSpring.snappy)) {
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
                    withAnimation(.inkSpring(InkSpring.snappy)) {
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
        withAnimation(.inkSpring(InkSpring.snappy)) {
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
            withAnimation(.inkSpring(InkSpring.snappy)) {
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
                withAnimation(.inkSpring(InkSpring.snappy)) {
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
        guard !notebook.autoHideHeader else { return }
        headerManualReHideTask?.cancel()
        interactionGraceTask?.cancel()
        interactionGraceTask = nil
        if !headerVisibility.isHeaderVisible {
            withAnimation(.inkSpring(InkSpring.snappy)) {
                headerVisibility = .visible
            }
        }
    }

    // MARK: - Focus Mode

    func toggleFocusMode() {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            isFocusMode.toggle()
        }
    }

    // MARK: - Pencil Pro squeeze wheel

    /// Called by `PencilSqueezeDetector` on each squeeze. Toggles the wheel.
    /// `squeezeWheelCentre` is a sentinel — `nil` means hidden, any
    /// non-nil value means visible. The host view computes the real
    /// position from its own GeometryReader. Future: feed pencil hover
    /// position through this property.
    func handlePencilSqueeze() {
        if squeezeWheelCentre != nil {
            // Already up — second squeeze dismisses.
            squeezeWheelCentre = nil
            return
        }
        squeezeWheelCentre = .zero
        HapticManager.shared.contextMenuOpened()
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
    func selectTool(_ tool: InkTool) {
        if tool.identity != selectedTool.identity {
            // Snapshot the *outgoing* tool before we overwrite selectedTool.
            toolSettings.snapshot(selectedTool)
            toolSettings.save()
            lastTool = selectedTool
        }
        selectedTool = tool
        resetToolbarTimer()
    }

    /// Switch to a tool by identity — looks up persisted per-tool settings
    /// (`ToolSettingsStore`) and falls back to defaults. This is what the
    /// tool palette should call when the user taps a tool button.
    func selectTool(identity: InkTool.Identity) {
        let restored = toolSettings.tool(for: identity, theme: theme)
        selectTool(restored)
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
                selectedTool = InkTool.Defaults.pen(theme: theme)
                lastTool     = current
            }
        } else {
            lastTool     = selectedTool
            selectedTool = InkTool.Defaults.eraser
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
        // detection routine replaces the stroke with a
        // `PDFTextAnnotationRecord` (highlight / underline /
        // strikethrough) and returns. Non-highlighter tools and
        // strokes over blank space fall through to the rest of this
        // method unchanged.
        if selectedTool.isHighlighterFamily, notebook.isPDFBacked {
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

        withAnimation(.inkSpring(InkSpring.fade)) {
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
                withAnimation(.inkSpring(InkSpring.fade)) {
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
        withAnimation(.inkSpring(InkSpring.fade)) {
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
        if case .eraser(.pixel) = selectedTool {
            setPixelEraserSize(selectedTool.currentWidth + 1)
            return
        }
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth + 0.5)
        persistCurrentToolSettings()
    }

    func decrementWidth() {
        guard selectedTool.hasWidth else { return }
        if case .eraser(.pixel) = selectedTool {
            setPixelEraserSize(selectedTool.currentWidth - 1)
            return
        }
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth - 0.5)
        persistCurrentToolSettings()
    }

    func setWidth(_ width: CGFloat) {
        if case .eraser(.pixel) = selectedTool {
            setPixelEraserSize(width)
            return
        }
        selectedTool = selectedTool.withWidth(width)
        persistCurrentToolSettings()
    }

    /// Pixel-eraser size lives in `ink.eraser.pixelSize.session` (a UserDefaults
    /// key cleared at app cold-launch). The PKEraserTool is rebuilt by
    /// re-emitting the same case so the canvas picks up the new bitmap width.
    private func setPixelEraserSize(_ width: CGFloat) {
        let clamped = max(4, min(80, width))
        UserDefaults.standard.set(Double(clamped), forKey: "ink.eraser.pixelSize.session")
        // Toggle selectedTool to force PKCanvasView to rebuild its tool.
        if case .eraser(.pixel) = selectedTool {
            selectedTool = .eraser(mode: .pixel)
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
        refreshCurrentPageAttachments()
        refreshCurrentPageAudioAnnotations()
        refreshCurrentPageStickyNotes()
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
    /// when at the last page and `ink.newpage.autoAdd` is on; also reachable
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

    func addPage(after pageNumber: Int? = nil) {
        guard let _ = try? storage.createPage(
            in: notebook,
            after: pageNumber ?? pages.last?.pageNumber,
            pageSize: globalPageSize,
            backgroundTemplate: globalTemplate
        ) else { return }
        refreshPages()
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
            // Force a drawing reload
            if let canvasView,
               let data    = pages[safeIndex].strokeData,
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

    func refreshPages() {
        let fetched = storage.fetchPages(in: notebook)
        guard !fetched.isEmpty else { return }
        pages = fetched
        currentPageIndex = max(0, min(currentPageIndex, pages.count - 1))
        refreshCurrentPageTextBlocks()
        refreshCurrentPageAttachments()
        refreshCurrentPageAudioAnnotations()
        refreshCurrentPageStickyNotes()
    }

    func refreshCurrentPageTextBlocks() {
        currentPageTextBlocks = (currentPage.textBlocks ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }
    }

    func refreshCurrentPageAttachments() {
        currentPageAttachments = (currentPage.mediaAttachments ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }
    }

    func refreshCurrentPageAudioAnnotations() {
        currentPageAudioAnnotations = (currentPage.audioAnnotations ?? [])
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Sticky notes

    /// Pull the latest sticky notes for the current page out of
    /// `StickyNoteStore` and republish so the canvas overlay
    /// re-renders.
    func refreshCurrentPageStickyNotes() {
        currentPageStickyNotes = StickyNoteStore.notes(for: currentPage.id)
    }

    /// Place a fresh sticky note at the given normalised position.
    /// Immediately puts the popover into "editing" mode so the user
    /// can type — placement and editing are a single user-perceived
    /// gesture.
    func addStickyNote(at normalised: CGPoint) {
        let record = StickyNoteStore.add(
            pageId:      currentPage.id,
            normalizedX: Double(normalised.x.clamped01),
            normalizedY: Double(normalised.y.clamped01)
        )
        refreshCurrentPageStickyNotes()
        editingStickyNoteId = record.id
    }

    func updateStickyNoteBody(id: UUID, body: String) {
        StickyNoteStore.updateBody(id: id, pageId: currentPage.id, body: body)
        refreshCurrentPageStickyNotes()
    }

    // MARK: - Lecture mode

    /// Mic-button menu → "Lecture". Spins up a fresh
    /// `LectureRecorder`, publishes it so the editor view swaps to
    /// `LectureRecordingView`, and kicks off recording. Failures
    /// (mic denied, engine couldn't start) clear the recorder
    /// silently — the user is back to the editor with no recording.
    func startLectureMode() async {
        guard activeLectureRecorder == nil else { return }
        let recorder = LectureRecorder()
        do {
            try await recorder.start(
                pageId:     currentPage.id,
                notebookId: notebook.id
            )
            activeLectureRecorder = recorder
        } catch {
            // Microphone denied or engine failure — surface via the
            // existing media-error banner so the user knows. Spec
            // says "never break existing recording" so we just bail.
            mediaError = AppError.humanize(error)
            activeLectureRecorder = nil
        }
    }

    /// Called by `LectureRecordingView.onStop` after the user
    /// confirms "end". Inserts the post-stop placeholder TextBlock,
    /// kicks the search index to ingest the transcript, and drops
    /// the recorder so the editor view restores.
    func endLectureMode(with record: LectureRecord?) {
        defer { activeLectureRecorder = nil }
        guard let record else { return }

        // Placeholder TextBlock body is just the marker — Pass B's
        // `LectureBlockView` looks up the full record from
        // `LectureStore` via the UUID suffix. Earlier passes also
        // appended a duration display line and (briefly) the full
        // transcript; both are gone here because the block view
        // renders title + duration + summary + transcript from the
        // record itself. Old serialised TextBlocks with the extra
        // lines continue to parse — `LectureBlockView` ignores
        // everything after the first line.
        let content = "lecture:\(record.id.uuidString)"
        _ = try? storage.createTextBlock(on: currentPage, content: content)
        refreshCurrentPageTextBlocks()

        // Bump the search index synchronously so the transcript is
        // searchable as soon as the user tries to find it. The pass
        // pulls from `LectureStore` for the lecture transcript field.
        SearchIndexService.shared.rebuildSynchronousMetadata(for: notebook)

        // Pass B — kick off AI summary generation on a detached
        // utility task. Silent no-op on iOS 18 / when canRun is
        // false; the editor never surfaces an "AI unavailable"
        // placeholder. The completion writes the updated record
        // back into `LectureStore`, which posts
        // `.lectureRecordUpdated` so `LectureBlockView` swaps
        // "summarising…" for the generated content live.
        Task.detached(priority: .utility) {
            await IntelligenceService.shared.generateLectureSummary(for: record)
        }
    }

    private func formatLectureDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m) min" }
        return "\(total) sec"
    }

    func deleteStickyNote(id: UUID) {
        StickyNoteStore.softDelete(id: id, pageId: currentPage.id)
        if editingStickyNoteId == id { editingStickyNoteId = nil }
        refreshCurrentPageStickyNotes()
    }

    // MARK: - Overlay-view StorageService wrappers
    //
    // The TextBlockOverlay, AudioAnnotationPinsOverlay, and Media overlay all
    // used to call `StorageService.shared` directly. These wrappers route the
    // mutations through the view model so views never depend on StorageService.

    /// Returns the created `TextBlock` so the overlay can install its layout
    /// state immediately. Refreshes `currentPageTextBlocks` and schedules
    /// autosave on success.
    @discardableResult
    func createTextBlock(at normalizedRect: CGRect) -> TextBlock? {
        guard let block = try? storage.createTextBlock(on: currentPage,
                                                       at: normalizedRect) else {
            return nil
        }
        refreshCurrentPageTextBlocks()
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

    func moveAudioAnnotation(_ annotation: AudioAnnotation, to point: CGPoint) {
        try? storage.moveAudioAnnotation(annotation, to: point)
        refreshCurrentPageAudioAnnotations()
        scheduleAutosave()
    }

    func deleteAudioAnnotation(_ annotation: AudioAnnotation) {
        try? storage.deleteAudioAnnotation(annotation)
        refreshCurrentPageAudioAnnotations()
        scheduleAutosave()
    }

    func deleteAttachment(_ attachment: MediaAttachment) {
        try? storage.deleteAttachment(attachment)
        refreshCurrentPageAttachments()
        scheduleAutosave()
    }

    func updateAttachment(
        _ attachment: MediaAttachment,
        rect: CGRect? = nil,
        rotation: Double? = nil,
        opacity: Double? = nil,
        caption: String? = nil
    ) {
        try? storage.updateAttachment(attachment, rect: rect, rotation: rotation,
                                       caption: caption, opacity: opacity)
        scheduleAutosave()
    }

    func updateAttachmentZIndex(_ attachment: MediaAttachment, zIndex: Int) {
        try? storage.updateAttachmentZIndex(attachment, zIndex: zIndex)
        refreshCurrentPageAttachments()
        scheduleAutosave()
    }

    func replaceAttachmentImage(
        _ attachment: MediaAttachment,
        jpegData: Data,
        originalWidth: Int,
        originalHeight: Int
    ) {
        try? storage.replaceAttachmentImage(attachment, jpegData: jpegData,
                                            originalWidth: originalWidth,
                                            originalHeight: originalHeight)
        scheduleAutosave()
    }

    /// Inserts an audio file (already copied to the audio directory) into the current
    /// page. Used by `AudioFilePicker` after it has finished copying / transcoding.
    @discardableResult
    func insertAudioFile(
        annotationId: UUID,
        fileName: String,
        duration: Double,
        fileSizeBytes: Int64,
        at point: CGPoint
    ) -> AudioAnnotation? {
        let annotation = try? storage.insertAudioFile(
            to: currentPage,
            annotationId: annotationId,
            fileName: fileName,
            duration: duration,
            fileSizeBytes: fileSizeBytes,
            at: point
        )
        if annotation != nil {
            refreshCurrentPageAudioAnnotations()
            scheduleAutosave()
        }
        return annotation
    }

    /// URL of the audio directory for the active notebook — needed by AudioFilePicker
    /// to write a transcoded copy before calling `insertAudioFile(from:...)`.
    func audioDirURL() -> URL {
        storage.audioDirURL(notebookId: currentPage.notebookId)
    }

    // Read-only URL passthroughs — overlays use these to load image bytes for
    // Copy / Crop / display without depending on StorageService directly.
    func mediaURL(for attachment: MediaAttachment) -> URL {
        storage.mediaURL(for: attachment)
    }
    func thumbnailURL(for attachment: MediaAttachment) -> URL {
        storage.thumbnailURL(for: attachment)
    }
    func audioURL(for annotation: AudioAnnotation) -> URL {
        storage.audioURL(for: annotation)
    }

    // MARK: - Attachment undo (session-only shake/toolbar undo)

    func registerAttachmentUndo(_ attachment: MediaAttachment) {
        let data = try? Data(contentsOf: StorageService.shared.mediaURL(for: attachment))
        deletedAttachmentsUndo.append((attachment, data))
    }

    func undoLastAttachmentDelete() {
        guard let (attachment, _) = deletedAttachmentsUndo.popLast() else { return }
        try? StorageService.shared.restoreAttachment(attachment)
        refreshCurrentPageAttachments()
    }

    var canUndoAttachmentDelete: Bool { !deletedAttachmentsUndo.isEmpty }

    // MARK: - Audio recording

    func startRecording() async {
        do {
            try await audioRecorder.requestPermission()
            let dir = StorageService.shared.audioDirURL(notebookId: currentPage.notebookId)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let tempId  = UUID()
            let fileURL = dir.appendingPathComponent(tempId.uuidString + ".m4a")
            try await audioRecorder.start(outputURL: fileURL)
            recordingState = .recording
            pendingRecordingURL = fileURL
            pendingRecordingId  = tempId
        } catch {
            mediaError = AppError.humanize(error)
        }
    }

    func stopRecording() async {
        guard recordingState == .recording else { return }
        recordingState = .processing
        do {
            let result = try await audioRecorder.stop()
            guard let url = pendingRecordingURL, let id = pendingRecordingId else {
                recordingState = .idle
                return
            }

            // Read both toggles fresh at stop-time so Settings changes
            // apply immediately. The per-recording `isTranscriptionEnabled`
            // override (the panel's "Transcribe" switch) gates further;
            // the master "Save audio clips" toggle has no per-recording
            // override since it's an always-on default.
            let saveAudio  = UserDefaults.standard.object(forKey: "ink.audio.saveClips") as? Bool ?? true
            let transcribe = isTranscriptionEnabled

            // Both off — nothing to keep. Discard the temp file and
            // dismiss; the panel already showed the "both off" hint.
            guard saveAudio || transcribe else {
                try? FileManager.default.removeItem(at: url)
                pendingRecordingURL = nil
                pendingRecordingId  = nil
                recordingState      = .idle
                isRecordingPanelVisible = false
                return
            }

            if saveAudio {
                let pinPoint = CGPoint(x: 0.15, y: 0.15)
                let annotation = try StorageService.shared.insertAudioFile(
                    to: currentPage,
                    annotationId: id,
                    fileName: id.uuidString + ".m4a",
                    duration: result.duration,
                    fileSizeBytes: result.fileSizeBytes,
                    at: pinPoint
                )
                refreshCurrentPageAudioAnnotations()
                pendingRecordingURL = nil
                pendingRecordingId  = nil
                recordingState      = .idle
                isRecordingPanelVisible = false

                if transcribe {
                    let capturedURL = url
                    let capturedId  = annotation.id
                    Task.detached(priority: .utility) { [weak self] in
                        await SpeechTranscriber.shared.transcribe(url: capturedURL, annotationId: capturedId)
                        await MainActor.run { [weak self] in
                            self?.refreshCurrentPageAudioAnnotations()
                        }
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
                isRecordingPanelVisible = false

                Task.detached(priority: .utility) { [weak self] in
                    let result = await SpeechTranscriber.shared.transcribeFile(url: capturedURL)
                    try? FileManager.default.removeItem(at: capturedURL)
                    guard let text = result?.text, !text.isEmpty else { return }
                    // Hop to MainActor as a Task (not `MainActor.run`)
                    // and forward `self` through the closure capture
                    // list so Swift 6 strict-concurrency doesn't flag
                    // the var-capture of weak self into the
                    // synchronously-evaluated `MainActor.run` body.
                    await Task { @MainActor [weak self] in
                        _ = try? StorageService.shared.createTextBlock(on: capturedPage, content: text)
                        self?.refreshCurrentPageTextBlocks()
                    }.value
                }
            }
        } catch {
            mediaError     = AppError.humanize(error)
            recordingState = .idle
        }
    }

    /// Returns the AudioRecorder's live level stream for the waveform view.
    func audioLevelStream() async -> AsyncStream<Float> {
        await audioRecorder.levelStream ?? AsyncStream { $0.finish() }
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
            objectWillChange.send()
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
            objectWillChange.send()
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
            userDefaults.set(cover.rawValue, forKey: "ink.lastUsed.cover")
            objectWillChange.send()
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
            if let first = (notebook.pages ?? []).first(where: { $0.pageNumber == 1 && !$0.isDeleted }),
               first.strokeData == nil || first.strokeDataSize == 0 {
                first.pageSize  = size
                first.updatedAt = Date()
            }
            userDefaults.set(size.rawValue, forKey: "ink.lastUsed.pageSize")
            objectWillChange.send()
        } catch {
            showError(.storageFailed(action: "update page size", underlying: error))
        }
    }

    /// Apply a page template. Same empty-page rule as `applyCustomPageSize`.
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
            if let first = (notebook.pages ?? []).first(where: { $0.pageNumber == 1 && !$0.isDeleted }),
               first.strokeData == nil || first.strokeDataSize == 0 {
                first.backgroundTemplate = template
                first.updatedAt          = Date()
            }
            userDefaults.set(template.jsonString, forKey: "ink.lastUsed.template")
            objectWillChange.send()
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
            scheduleThumbnailRegeneration(for: page, drawing: drawing)
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
            scheduleThumbnailRegeneration(for: page, drawing: drawing)
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

    /// Regenerate the page thumbnail off the drawing thread.
    private func scheduleThumbnailRegeneration(for page: Page, drawing: PKDrawing) {
        let pageSize = page.pageSize.pointSize
        let pageId   = page.id
        Task.detached(priority: .utility) {
            let bounds = CGRect(origin: .zero, size: pageSize)
            let scale: CGFloat = 0.20  // ~ 200×260 thumbnail dimensions
            let image  = drawing.image(from: bounds, scale: scale)
            await MainActor.run {
                PageThumbnailCache.shared.set(image, for: pageId)
            }
        }
    }

    // MARK: - Exit

    /// Called when the user taps Back. Triggers a flush save before dismissing.
    func prepareForDismissal() {
        toolbarHideTask?.cancel()
        flushPendingSaveSync()
        // Focus Mode is editor-scoped — exit on the way back to Library so
        // the next notebook opens with normal chrome.
        isFocusMode = false
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

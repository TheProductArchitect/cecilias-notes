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
    @Published var isShowingPageStrip: Bool = false
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
    }

    func closeCustomisePanel() {
        isCustomisePanelOpen = false
    }

    // MARK: Export
    @Published var isShowingExportSheet: Bool = false

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
    @Published var playingAnnotationId:         UUID?     = nil
    @Published var isRecordingPanelVisible:     Bool      = false
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
        storage: StorageService = .shared,
        userDefaults: UserDefaults = .standard,
        theme: InkTheme = .light
    ) {
        self.notebook        = notebook
        self.storage         = storage
        self.userDefaults    = userDefaults
        self.theme           = theme

        let fetched = storage.fetchPages(in: notebook)
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
    }

    deinit {
        // Tasks captured [weak self] — they will be no-ops after dealloc.
        toolbarHideTask?.cancel()
        saveTask?.cancel()
        savedFlashTask?.cancel()
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

    func toggleEraser() {
        if case .eraser = selectedTool {
            // Cycle whole-stroke ↔ pixel. .page is a one-shot action, not part of the cycle.
            if case .eraser(.pixel) = selectedTool {
                selectedTool = .eraser(mode: .wholeStroke)
            } else {
                selectedTool = .eraser(mode: .pixel)
            }
        } else {
            lastTool     = selectedTool
            selectedTool = InkTool.Defaults.eraser
        }
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
            await MainActor.run {
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
    /// Returns true on success.
    @discardableResult
    func goToPage(index newIndex: Int) -> Bool {
        guard newIndex >= 0, newIndex < pages.count, newIndex != currentPageIndex else {
            return false
        }
        guard let canvasView else {
            currentPageIndex = newIndex
            return true
        }

        // Track elapsed time so we can show a loading indicator if the swap is unexpectedly slow.
        let start = Date()

        // 1. Save outgoing — synchronous, ignore errors (autosave will retry shortly)
        flushPendingSaveSync()

        // 2. Swap drawing.
        //    Earlier work added a CATransition on canvasView.layer for a
        //    horizontal page-slide effect. That broke PencilKit's live
        //    stroke preview — the in-flight Metal render in
        //    PKCanvasAttachmentView (a sublayer) inherited the transition
        //    and stuck on screen as a "shadow" of the pen tip after pen-up.
        //    The slide is removed; pages now swap instantly.
        let outgoing = pages[currentPageIndex]
        let incoming = pages[newIndex]

        if let data    = incoming.strokeData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        } else {
            canvasView.drawing = PKDrawing()
        }

        // Reset undo manager scope so undoes don't bleed across pages.
        canvasView.undoManager?.removeAllActions()

        currentPageIndex = newIndex
        isDirty          = false
        saveStatus       = .idle
        refreshCurrentPageTextBlocks()
        refreshCurrentPageAttachments()
        refreshCurrentPageAudioAnnotations()

        let elapsed = Date().timeIntervalSince(start)
        if elapsed > 0.1 { pageSwapInFlight = true }
        else             { pageSwapInFlight = false }

        // Invalidate any stale thumbnails for the outgoing page — defer to the strip's cache.
        PageThumbnailCache.shared.invalidate(pageId: outgoing.id)
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

    /// Reads `ink.newpage.autoAdd` from UserDefaults. Default is `true` (matches
    /// the SettingsViewModel `@AppStorage` default).
    var autoAddEnabled: Bool {
        UserDefaults.standard.object(forKey: "ink.newpage.autoAdd") as? Bool ?? true
    }

    /// Page size from global Settings, falling back to the notebook's own setting.
    private var globalPageSize: PageSize {
        guard let raw = UserDefaults.standard.string(forKey: "ink.newpage.size"),
              let size = PageSize(rawValue: raw) else { return notebook.pageSize }
        return size
    }

    /// Template from global Settings, falling back to the notebook's own setting.
    private var globalTemplate: PageTemplate {
        guard let raw = UserDefaults.standard.string(forKey: "ink.newpage.template"),
              let data = raw.data(using: .utf8),
              let template = try? JSONDecoder().decode(PageTemplate.self, from: data)
        else { return notebook.defaultTemplate }
        return template
    }

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

    private func refreshPages() {
        let fetched = storage.fetchPages(in: notebook)
        guard !fetched.isEmpty else { return }
        pages = fetched
        currentPageIndex = max(0, min(currentPageIndex, pages.count - 1))
        refreshCurrentPageTextBlocks()
        refreshCurrentPageAttachments()
        refreshCurrentPageAudioAnnotations()
    }

    func refreshCurrentPageTextBlocks() {
        currentPageTextBlocks = currentPage.textBlocks
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }
    }

    func refreshCurrentPageAttachments() {
        currentPageAttachments = currentPage.mediaAttachments
            .filter { !$0.isDeleted }
            .sorted { $0.zIndex < $1.zIndex }
    }

    func refreshCurrentPageAudioAnnotations() {
        currentPageAudioAnnotations = currentPage.audioAnnotations
            .filter { !$0.isDeleted }
            .sorted { $0.createdAt < $1.createdAt }
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

            if isTranscriptionEnabled {
                let capturedURL = url
                let capturedId  = annotation.id
                Task.detached(priority: .utility) { [weak self] in
                    await SpeechTranscriber.shared.transcribe(url: capturedURL, annotationId: capturedId)
                    await MainActor.run { self?.refreshCurrentPageAudioAnnotations() }
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
            if let first = notebook.pages.first(where: { $0.pageNumber == 1 && !$0.isDeleted }),
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
            if let first = notebook.pages.first(where: { $0.pageNumber == 1 && !$0.isDeleted }),
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
        guard isDirty, let canvasView, let storage = Optional(self.storage) else { return }
        let drawing = canvasView.drawing
        let page    = currentPage
        do {
            try storage.updatePageStrokes(page, drawing: drawing)
            isDirty    = false
            saveStatus = .saved
            scheduleSavedFlash()
            scheduleThumbnailRegeneration(for: page, drawing: drawing)
        } catch {
            saveStatus = .error(error.localizedDescription)
        }
    }

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

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

    // MARK: Tool palette position (persisted)
    @Published var toolPalettePosition: CGPoint = CGPoint(x: 0, y: 0)

    // MARK: Recent colours (persisted)
    @Published private(set) var recentColours: [UIColor] = []

    // MARK: Notebook title editing
    @Published var isEditingTitle: Bool = false

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

    // MARK: Storage
    private let storage: StorageService
    private let userDefaults: UserDefaults
    private var cancellables = Set<AnyCancellable>()

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
        self.selectedTool     = InkTool.Defaults.pen(theme: theme)

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
        static let toolPalettePosition = "ink.toolPalette.position"
        static let recentColours       = "ink.colorPicker.recent"
        // Must stay in lock-step with SettingsViewModel.DoubleTapAction's @AppStorage key.
        static let pencilDoubleTap     = "ink.pencil.doubletap"
    }

    private func loadPersistedState(theme: InkTheme) {
        // Tool palette position — default: right edge, vertically centred
        if let data  = userDefaults.data(forKey: StorageKeys.toolPalettePosition),
           let point = try? JSONDecoder().decode(CGPointWrapper.self, from: data) {
            toolPalettePosition = point.cgPoint
        } else {
            // Will be repositioned by ToolPaletteView on first appear once the bounds are known.
            toolPalettePosition = CGPoint(x: -1, y: -1)
        }

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

    func persistToolPalettePosition() {
        if let data = try? JSONEncoder().encode(CGPointWrapper(cgPoint: toolPalettePosition)) {
            userDefaults.set(data, forKey: StorageKeys.toolPalettePosition)
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

    // MARK: - Tool selection

    /// Switch tool, remembering the previous selection so "switch between two tools"
    /// (Apple Pencil double-tap) can ping-pong.
    func selectTool(_ tool: InkTool) {
        if tool.identity != selectedTool.identity {
            lastTool = selectedTool
        }
        selectedTool = tool
        resetToolbarTimer()
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

    func incrementWidth() {
        guard selectedTool.hasWidth else { return }
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth + 0.5)
    }

    func decrementWidth() {
        guard selectedTool.hasWidth else { return }
        selectedTool = selectedTool.withWidth(selectedTool.currentWidth - 0.5)
    }

    func setWidth(_ width: CGFloat) {
        selectedTool = selectedTool.withWidth(width)
    }

    func setOpacity(_ opacity: CGFloat) {
        selectedTool = selectedTool.withOpacity(opacity)
    }

    // MARK: - Colour selection

    func selectColour(_ colour: UIColor) {
        selectedTool = selectedTool.withColour(colour)
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
        } catch {
            showError(.storageFailed(action: "rename notebook", underlying: error))
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
    }
}

// MARK: - CGPoint codable wrapper

private struct CGPointWrapper: Codable {
    let x: CGFloat
    let y: CGFloat
    init(cgPoint: CGPoint) { x = cgPoint.x; y = cgPoint.y }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
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

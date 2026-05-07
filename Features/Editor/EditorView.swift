import PencilKit
import SwiftUI

/// Full-screen editor. Composition (back-to-front):
///   1. CanvasContainerView (PKCanvasView in UIScrollView)
///   2. ToolPaletteView (floating right-edge pill)
///   3. PageStripView (slides up from bottom)
///   4. MinimapView (bottom-right when zoom > 1.5)
///   5. EditorToolbarView (top, blur background, auto-hides)
///   6. Top-edge tap restorer (60pt invisible strip to bring toolbar back)
struct EditorView: View {
    @StateObject var viewModel: EditorViewModel
    let onDismiss: () -> Void

    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var deepLink:     DeepLinkRouter

    @State private var canvasFrame: CGRect = .zero
    @State private var canUndo: Bool = false
    @State private var canRedo: Bool = false
    @State private var undoTimer: Timer?

    init(notebook: Notebook, onDismiss: @escaping () -> Void) {
        _viewModel = StateObject(wrappedValue: EditorViewModel(notebook: notebook))
        self.onDismiss = onDismiss
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // 1. Canvas (full screen) + text block overlay (inside scroll/zoom space)
                CanvasContainerView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .onAppear { canvasFrame = proxy.frame(in: .global) }
                    .accessibilityLabel(A11y.canvasLabel(strokeCount: viewModel.strokeCount))
                    .accessibilityHint(A11y.canvasHint)

                // 2. Floating tool palette
                if !viewModel.isFullScreen {
                    ToolPaletteView(viewModel: viewModel, parentSize: proxy.size)
                }

                // 3. Page strip (bottom)
                if viewModel.isShowingPageStrip && !viewModel.isFullScreen {
                    VStack {
                        Spacer()
                        PageStripView(viewModel: viewModel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea()
                }

                // 4. Minimap (when zoomed in)
                if viewModel.zoomScale > 1.5 && !viewModel.isFullScreen {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            MinimapView(viewModel: viewModel)
                                .padding(.trailing, Ink.Spacing.lg)
                                .padding(.bottom,
                                         viewModel.isShowingPageStrip ? 156 : Ink.Spacing.lg)
                        }
                    }
                    .transition(.opacity)
                    .allowsHitTesting(true)
                }

                // 5. Top toolbar
                if !viewModel.isFullScreen {
                    VStack(spacing: 0) {
                        EditorToolbarView(
                            viewModel: viewModel,
                            onBack: { onDismiss() },
                            onUndo: undo,
                            onRedo: redo,
                            canUndo: canUndo,
                            canRedo: canRedo,
                            onShare: shareNotebook,
                            onTogglePageStrip: togglePageStrip,
                            onMoreMenuExportPDF: exportPDF,
                            onMoreMenuPrint: printNotebook,
                            onMoreMenuDuplicatePage: duplicateCurrentPage,
                            onMoreMenuDeletePage: deleteCurrentPage,
                            onMoreMenuPageSettings: showPageSettings,
                            onMoreMenuFullScreen: toggleFullScreen,
                            onMoreMenuInsertMedia: { viewModel.mediaInsertCoordinator.insertPhotos() },
                            onToggleRecordingPanel: toggleRecordingPanel
                        )
                        Spacer()
                    }
                }

                // 6. Top-edge tap restorer (60pt invisible band)
                VStack {
                    Color.clear
                        .frame(height: 60)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.resetToolbarTimer() }
                    Spacer()
                }
                .allowsHitTesting(!viewModel.isToolbarVisible)

                // Full-screen exit tap
                if viewModel.isFullScreen {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.inkSpring(InkSpring.smooth)) {
                                viewModel.isFullScreen = false
                                viewModel.resetToolbarTimer()
                            }
                        }
                        .ignoresSafeArea()
                }

                // Page swap loading indicator (only if swap > 100ms)
                if viewModel.pageSwapInFlight {
                    Color.black.opacity(0.15)
                        .ignoresSafeArea()
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }

                // Media processing progress HUD (PDF rasterisation etc.)
                if viewModel.mediaInsertCoordinator.isProcessing {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                    VStack(spacing: Ink.Spacing.sm) {
                        ProgressView(value: viewModel.mediaInsertCoordinator.processingProgress)
                            .tint(.white)
                            .frame(width: 200)
                        Text("Processing…")
                            .font(.inkCaption)
                            .foregroundColor(.white)
                    }
                    .padding(Ink.Spacing.lg)
                    .background(Color.inkBackgroundElevated.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.lg, style: .continuous))
                }

                // Error banner — slides from top
                if let error = viewModel.mediaError {
                    VStack {
                        MediaErrorBanner(message: error) {
                            viewModel.mediaError = nil
                        }
                        .padding(.top, 64)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(99)
                }

                // Recording panel — slides up from bottom
                if viewModel.isRecordingPanelVisible && !viewModel.isFullScreen {
                    RecordingPanelView(viewModel: viewModel)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(50)
                }
            }
            .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        }
        // Media picker sheets
        .sheet(item: $viewModel.activeMediaSource) { source in
            mediaPickerSheet(for: source)
        }
        // Audio file picker sheet
        .sheet(isPresented: $viewModel.isShowingAudioFilePicker) {
            AudioFilePicker(viewModel: viewModel) {
                viewModel.isShowingAudioFilePicker = false
            }
        }
        // Export options sheet
        .sheet(isPresented: $viewModel.isShowingExportSheet) {
            ExportOptionsView(
                notebook: viewModel.notebook,
                pages: viewModel.pages,
                currentIndex: viewModel.currentPageIndex
            ) {
                viewModel.isShowingExportSheet = false
            }
        }
        .statusBarHidden(viewModel.isFullScreen)
        .onAppear {
            startUndoStateTimer()
            // Library "Share as PDF…" deep-link: present the export sheet immediately.
            if deepLink.pendingExport {
                deepLink.pendingExport = false
                viewModel.isShowingExportSheet = true
            }
        }
        .onDisappear {
            undoTimer?.invalidate()
            undoTimer = nil
            viewModel.prepareForDismissal()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { note in
            handleKeyboardWillShow(note)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            withAnimation(.inkSpring(InkSpring.smooth)) {
                viewModel.keyboardVisibleHeight = 0
            }
        }
        // Keyboard shortcuts (external keyboard)
        .background(
            VStack(spacing: 0) {
                Button("Undo")     { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canUndo)
                Button("Redo")     { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canRedo)
                Button("Export")   { exportPDF() }
                    .keyboardShortcut("e", modifiers: .command)
                Button("Print")    { printNotebook() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Previous Page") { viewModel.goToPreviousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Page")     { viewModel.goToNextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Close Editor")  { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Toggle Toolbar") { viewModel.resetToolbarTimer() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Pen")         { viewModel.selectTool(.Defaults.pen(theme: themeManager.theme)) }
                    .keyboardShortcut("1", modifiers: [])
                Button("Highlighter") { viewModel.selectTool(.Defaults.highlighter) }
                    .keyboardShortcut("2", modifiers: [])
                Button("Pencil")      { viewModel.selectTool(.Defaults.pencil(theme: themeManager.theme)) }
                    .keyboardShortcut("3", modifiers: [])
                Button("Eraser")      { viewModel.selectTool(.Defaults.eraser) }
                    .keyboardShortcut("4", modifiers: [])
                Button("Lasso")       { viewModel.selectTool(.Defaults.lasso) }
                    .keyboardShortcut("5", modifiers: [])
                Button("Ruler")       { viewModel.selectTool(.Defaults.ruler) }
                    .keyboardShortcut("6", modifiers: [])
                Button("Text Tool")   { viewModel.selectTool(.Defaults.text) }
                    .keyboardShortcut("t", modifiers: [])
            }
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        )
        .onReceive(
            NotificationCenter.default.publisher(for: .inkCanvasShouldPanTo)
        ) { note in
            // Forward minimap pan to scroll view via the canvas container
            if let offset = note.userInfo?["offset"] as? CGPoint {
                // The CanvasContainerView observes scrollView directly; ideally we'd
                // route through it, but for Stage 4 we set it via the canvasView's
                // superview hierarchy.
                if let scrollView = viewModel.canvasView?
                    .superview?
                    .superview as? UIScrollView {
                    scrollView.setContentOffset(offset, animated: false)
                }
            }
        }
    }

    // MARK: Undo / redo state polling

    /// PKCanvasView's undoManager doesn't publish state. We poll it cheaply on a 200ms timer
    /// (only while the editor is on screen) so the toolbar Undo/Redo enabled state is correct.
    private func startUndoStateTimer() {
        undoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
            DispatchQueue.main.async {
                guard let mgr = viewModel.canvasView?.undoManager else { return }
                if canUndo != mgr.canUndo { canUndo = mgr.canUndo }
                if canRedo != mgr.canRedo { canRedo = mgr.canRedo }
            }
        }
    }

    // MARK: Toolbar callbacks

    private func undo() {
        viewModel.canvasView?.undoManager?.undo()
        viewModel.scheduleAutosave()
    }

    private func redo() {
        viewModel.canvasView?.undoManager?.redo()
        viewModel.scheduleAutosave()
    }

    private func togglePageStrip() {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            viewModel.isShowingPageStrip.toggle()
        }
        viewModel.resetToolbarTimer()
    }

    private func toggleFullScreen() {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            viewModel.isFullScreen.toggle()
            if viewModel.isFullScreen {
                viewModel.isShowingPageStrip = false
                viewModel.isToolbarVisible   = false
            } else {
                viewModel.isToolbarVisible = true
                viewModel.resetToolbarTimer()
            }
        }
    }

    private func duplicateCurrentPage() {
        viewModel.duplicatePage(viewModel.currentPage)
    }

    private func deleteCurrentPage() {
        viewModel.deletePage(viewModel.currentPage)
    }

    private func toggleRecordingPanel() {
        withAnimation(.inkSpring(InkSpring.smooth)) {
            viewModel.isRecordingPanelVisible.toggle()
        }
        viewModel.resetToolbarTimer()
    }

    private func showPageSettings() {
        // Stage 5+ — present a sheet with template/size pickers for current page
    }

    private func exportPDF() {
        viewModel.isShowingExportSheet = true
    }

    /// Routes through the export sheet so the user gets a real PDF + Share button
    /// (rather than sharing just the title string, which the previous stub did).
    private func shareNotebook() {
        viewModel.isShowingExportSheet = true
    }

    /// Renders the notebook to PDF in the background and presents
    /// `UIPrintInteractionController` with the resulting data set as `printingItem`.
    /// The previous stub configured `printInfo` but never set `printingItem`, so it
    /// effectively did nothing.
    private func printNotebook() {
        guard UIPrintInteractionController.isPrintingAvailable else { return }
        let nb   = viewModel.notebook
        let pgs  = viewModel.pages
        let opts = ExportOptions()
        Task {
            do {
                let result = try await ExportService.shared.exportNotebook(nb, pages: pgs, options: opts) { _ in }
                let data = try Data(contentsOf: result.fileURL)
                await MainActor.run {
                    let printer       = UIPrintInteractionController.shared
                    let info          = UIPrintInfo(dictionary: nil)
                    info.jobName      = nb.title
                    info.outputType   = .general
                    printer.printInfo = info
                    printer.printingItem = data
                    printer.present(animated: true)
                }
            } catch {
                // Best-effort: surface via existing media/error banner if needed.
            }
        }
    }

    // MARK: Media picker sheets

    @ViewBuilder
    private func mediaPickerSheet(for source: MediaSource) -> some View {
        let coord = viewModel.mediaInsertCoordinator
        switch source {
        case .photos:
            PhotoLibraryPicker { images in
                Task { await coord.handlePickedImages(images) }
            }
        case .files:
            FilesPicker { urls in
                Task { await coord.handlePickedFileURLs(urls) }
            }
        case .camera:
            CameraPicker {
                Task { await coord.handleCameraImage($0) }
            } onCancel: {
                viewModel.activeMediaSource = nil
            }
        case .scan:
            DocumentScannerPicker { scan in
                Task { await coord.handleScannedDocument(scan) }
            } onCancel: {
                viewModel.activeMediaSource = nil
            }
        }
    }

    // MARK: Keyboard management

    private func handleKeyboardWillShow(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let frame    = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curve    = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }
        let options = UIView.AnimationOptions(rawValue: curve << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            viewModel.keyboardVisibleHeight = frame.height
        }
    }
}

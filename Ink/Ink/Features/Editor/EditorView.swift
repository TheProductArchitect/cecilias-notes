import PencilKit
import SwiftUI

/// Full-screen editor. Composition (back-to-front):
///   1. CanvasContainerView (PKCanvasView in UIScrollView)
///   2. ToolPaletteView (edge-snapping pill — top in portrait, right in landscape by default)
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

                // Tap-outside-to-dismiss while the title is being renamed.
                // Active ONLY while editing — does not steal canvas touches
                // at any other time. Resigning first responder fires the
                // toolbar's onChange(of: titleFocused) which auto-saves.
                if viewModel.isEditingTitle {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                        .zIndex(50)
                }

                // 2. Floating tool palette — dims in Focus Mode but stays
                // mounted so re-emerging on exit is instant.
                if !viewModel.isFullScreen {
                    ToolPaletteView(
                        viewModel: viewModel,
                        parentSize: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                    .opacity(viewModel.isFocusMode ? 0.3 : 1.0)
                    .animation(.inkSpring(InkSpring.fade), value: viewModel.isFocusMode)
                }

                // 3. Page strip (bottom) — fully hidden in Focus Mode
                if viewModel.isShowingPageStrip && !viewModel.isFullScreen {
                    VStack {
                        Spacer()
                        PageStripView(viewModel: viewModel)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    .ignoresSafeArea()
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                }

                // 4. Minimap (when zoomed in) — fully hidden in Focus Mode
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
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                }

                // 5. Top toolbar — hidden in Focus Mode
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
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                }

                // 5y. Customise pill (Item 1) — surfaces top-right for ~5s
                // after a fresh notebook is created. Tap → open the panel.
                if viewModel.isCustomisePillVisible
                    && !viewModel.isFullScreen
                    && !viewModel.isFocusMode
                    && !viewModel.isCustomisePanelOpen {
                    VStack {
                        HStack {
                            Spacer()
                            CustomisePill(
                                onTap:     { viewModel.openCustomisePanel() },
                                onDismiss: { viewModel.dismissCustomisePill() }
                            )
                            .padding(.trailing, Ink.Spacing.md)
                            .padding(.top, proxy.safeAreaInsets.top + 60)  // below toolbar
                        }
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(72)
                }

                // 5x. Customise panel — slide-down overlay, non-modal.
                // Tap-outside layer captures stray taps to dismiss while
                // letting the panel itself remain interactive.
                if viewModel.isCustomisePanelOpen {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            withAnimation(.inkSpring(InkSpring.smooth)) {
                                viewModel.closeCustomisePanel()
                            }
                        }
                        .zIndex(73)

                    VStack {
                        CustomisePanel(viewModel: viewModel)
                            .padding(.top, proxy.safeAreaInsets.top + 52) // below toolbar
                        Spacer()
                    }
                    .zIndex(74)
                }

                // 5z. Shape recognition "Undo Shape" pill — floats at the
                // top-centre when a stroke was just replaced. Tap to revert,
                // auto-dismisses after 5s; the conversion is then committed
                // (still undoable via standard ⌘Z). Visually a touch louder
                // than the equivalent "Customise" pill — the user just lost
                // a stroke they drew, so a calmer "Undo Shape" wouldn't
                // catch the eye in time.
                if viewModel.pendingShapeUndo != nil {
                    VStack {
                        Button {
                            viewModel.undoShapeReplacement()
                        } label: {
                            HStack(spacing: Ink.Spacing.xs) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.inkSubhead)
                                    .fontWeight(.semibold)
                                Text("Undo Shape")
                                    .font(.inkSubhead)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, Ink.Spacing.md)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(Color.inkAccentPrimary)
                                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                            )
                        }
                        .buttonStyle(.inkPressable)
                        .padding(.top, proxy.safeAreaInsets.top + 60)   // below toolbar
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(70)
                }

                // 5a. Focus Mode exit pill (top-right). Semi-transparent so
                // it doesn't compete with the writing. Also dismissable via
                // two-finger long-press anywhere (set up further down).
                if viewModel.isFocusMode {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                viewModel.toggleFocusMode()
                            } label: {
                                HStack(spacing: Ink.Spacing.xs) {
                                    Image(systemName: "xmark")
                                        .font(.inkCaption)
                                    Text("Exit Focus")
                                        .font(.inkCaption)
                                }
                                .foregroundColor(.inkTextPrimary)
                                .padding(.horizontal, Ink.Spacing.sm)
                                .padding(.vertical, Ink.Spacing.xs)
                                .background(
                                    Capsule()
                                        .fill(Color.inkBackgroundElevated.opacity(0.85))
                                )
                            }
                            .buttonStyle(.inkPressable)
                            .opacity(0.6)
                            .padding(.top, proxy.safeAreaInsets.top + Ink.Spacing.sm)
                            .padding(.trailing, Ink.Spacing.md)
                        }
                        Spacer()
                    }
                    .transition(.opacity)
                    .zIndex(60)
                }

                // 5b. Two-finger long-press anywhere → exit Focus Mode.
                // Wrapped in a UIViewRepresentable that only claims a touch
                // when 2+ fingers are down — so single-finger drawing is
                // never disturbed.
                if viewModel.isFocusMode {
                    TwoFingerLongPressDetector { viewModel.toggleFocusMode() }
                        .ignoresSafeArea()
                        .zIndex(55)
                }

                // 5c. Apple Pencil Pro squeeze detector. Always mounted —
                // gracefully no-ops on iOS 17.0–17.4 / non-Pro Pencils.
                // Lives at zIndex 0 underneath everything; takes no hits.
                PencilSqueezeDetector {
                    viewModel.handlePencilSqueeze()
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // 5d. Radial wheel summoned by squeeze. Centre uses
                // the editor viewport centre (squeezeWheelCentre is a
                // .zero sentinel meaning "use viewport centre" — when
                // pencil hover tracking lands later, we'll feed a real
                // point through this same property).
                if viewModel.squeezeWheelCentre != nil {
                    let items: [WheelItem] = viewModel.isFocusMode
                        ? WheelItem.focusModeSet
                        : WheelItem.defaultSet
                    let centre = CGPoint(
                        x: proxy.size.width  / 2,
                        y: proxy.size.height / 2
                    )
                    RadialToolWheel(
                        items: items,
                        center: centre,
                        onSelect: { viewModel.handleWheelSelection($0) },
                        onDismiss: { viewModel.dismissSqueezeWheel() }
                    )
                    .transition(.opacity)
                    .zIndex(80)
                }

                // 6. Persistent back button + top-edge restorer.
                //    The back button itself is ALWAYS in the hierarchy, hit-testable
                //    regardless of toolbar visibility. Previously this was gated on
                //    `!isToolbarVisible`, which created a race window during the
                //    toolbar's auto-hide animation: the toolbar's allowsHitTesting
                //    flipped to false immediately while SwiftUI deferred inserting
                //    this overlay by one runloop tick (due to .transition), so a tap
                //    landing in that window hit nothing and the user had to tap twice.
                //    Visually it sits underneath the toolbar's own back button and is
                //    only revealed when the toolbar fades out.
                if !viewModel.isFullScreen {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button {
                                viewModel.prepareForDismissal()
                                onDismiss()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(.inkTextPrimary)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(Color.inkBackgroundElevated.opacity(0.88))
                                            // Hide the chip background when the
                                            // toolbar is showing; only the toolbar's
                                            // own back button is visible then.
                                            .opacity(viewModel.isToolbarVisible ? 0 : 1)
                                    )
                                    .opacity(viewModel.isToolbarVisible ? 0 : 1)
                            }
                            .buttonStyle(.inkPressable)
                            .padding(.leading, Ink.Spacing.md)
                            .padding(.top, Ink.Spacing.sm)
                            // When the toolbar is up, let *its* back button
                            // claim the tap. When it's hidden (or fading out),
                            // this button takes over — both flip at T=0 with
                            // `isToolbarVisible`, so there is no race window.
                            .allowsHitTesting(!viewModel.isToolbarVisible)
                            .accessibilityHidden(viewModel.isToolbarVisible)

                            // Top-edge restorer — only present when the toolbar is
                            // hidden, so it doesn't fight the toolbar's own gestures.
                            if !viewModel.isToolbarVisible {
                                Color.clear
                                    .frame(height: 60)
                                    .contentShape(Rectangle())
                                    .onTapGesture { viewModel.resetToolbarTimer() }
                            }
                        }
                        Spacer()
                    }
                }

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

                // Error banner — slides from top.
                // `error` (AppError) takes precedence over the legacy string
                // `mediaError`; both are dismissed on tap.
                if let message = viewModel.error?.errorDescription ?? viewModel.mediaError {
                    VStack {
                        MediaErrorBanner(message: message) {
                            viewModel.error = nil
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
        .statusBarHidden(viewModel.isFullScreen || viewModel.isFocusMode)
        .persistentSystemOverlays(viewModel.isFocusMode ? .hidden : .automatic)
        .onAppear {
            startUndoStateTimer()
            // Library "Share as PDF…" deep-link: present the export sheet immediately.
            // Reset the deep-link flag on the next runloop tick so the publisher
            // mutation doesn't land in this same view-update transaction.
            if deepLink.pendingExport {
                DispatchQueue.main.async { deepLink.pendingExport = false }
                viewModel.isShowingExportSheet = true
            }
            // Item 1 — surface the floating Customise pill iff this is a
            // freshly-created notebook we haven't already pilled this session.
            withAnimation(.inkSpring(InkSpring.smooth)) {
                viewModel.markCustomisePillIfFresh()
            }
        }
        .animation(.inkSpring(InkSpring.smooth), value: viewModel.isCustomisePanelOpen)
        .animation(.inkSpring(InkSpring.fade),   value: viewModel.isCustomisePillVisible)
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
        // ⌘W / ⌘⇧E / ⌘P / ⌘N / ⌘F come from the WindowGroup .commands modifier
        // (see InkCommands) and arrive as notifications.
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandCloseNotebook)) { _ in
            viewModel.prepareForDismissal()
            onDismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandExport)) { _ in
            exportPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .inkCommandPrint)) { _ in
            printNotebook()
        }
        // Per-screen shortcuts that should be disabled outside the editor stay
        // as hidden Buttons here. These don't appear in InkCommands deliberately.
        .background(
            VStack(spacing: 0) {
                Button("Undo")     { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canUndo)
                Button("Redo")     { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canRedo)
                Button("Previous Page") { viewModel.goToPreviousPage() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                Button("Next Page")     { viewModel.goToNextPage() }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Close Editor")  { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Toggle Toolbar") { viewModel.resetToolbarTimer() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Focus Mode") { viewModel.toggleFocusMode() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                // Tool shortcuts go through the identity-based selector so
                // the user's per-tool persisted settings (colour/width/opacity)
                // are restored, not reset to the default each time.
                Button("Pen")         { viewModel.selectTool(identity: .pen) }
                    .keyboardShortcut("1", modifiers: [])
                Button("Fountain Pen") { viewModel.selectTool(identity: .fountainPen) }
                    .keyboardShortcut("2", modifiers: [])
                Button("Brush")       { viewModel.selectTool(identity: .brush) }
                    .keyboardShortcut("3", modifiers: [])
                Button("Marker")      { viewModel.selectTool(identity: .marker) }
                    .keyboardShortcut("4", modifiers: [])
                Button("Pencil")      { viewModel.selectTool(identity: .pencil) }
                    .keyboardShortcut("5", modifiers: [])
                Button("Highlighter") { viewModel.selectTool(identity: .highlighter) }
                    .keyboardShortcut("6", modifiers: [])
                Button("Eraser")      { viewModel.selectTool(identity: .eraser) }
                    .keyboardShortcut("7", modifiers: [])
                Button("Lasso")       { viewModel.selectTool(identity: .lasso) }
                    .keyboardShortcut("8", modifiers: [])
                Button("Ruler")       { viewModel.selectTool(identity: .ruler) }
                    .keyboardShortcut("9", modifiers: [])
                Button("Text Tool")   { viewModel.selectTool(identity: .text) }
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

    /// PKCanvasView's undoManager doesn't publish state cleanly — global
    /// NSUndoManager notifications fire multiple times per stroke and
    /// cause SwiftUI re-renders that disrupt PencilKit's stroke-commit
    /// (the live preview gets stuck on screen as a "shadow" of the pen).
    ///
    /// A fixed 200ms timer is the pragmatic alternative: it never fires
    /// during a stroke commit, only between them, and the user-perceived
    /// latency on the Undo/Redo enabled state is imperceptible.
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
                await MainActor.run {
                    viewModel.showError(.printFailed(underlying: error))
                }
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
            CameraPicker { image in
                Task { await coord.handleCameraImage(image) }
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

// MARK: - TwoFingerLongPressDetector

/// Transparent UIView that fires `onTrigger` after a 0.5s two-finger
/// hold. Single-finger touches pass straight through — the underlying
/// canvas / drawing gestures are never disturbed.
///
/// Used for the Focus Mode escape hatch: hold two fingers anywhere to exit.
private struct TwoFingerLongPressDetector: UIViewRepresentable {
    let onTrigger: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = TwoFingerPassthroughView()
        let g = UILongPressGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handle(_:))
        )
        g.numberOfTouchesRequired = 2
        g.minimumPressDuration = 0.5
        g.cancelsTouchesInView = false
        v.addGestureRecognizer(g)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onTrigger: onTrigger) }

    final class Coordinator {
        let onTrigger: () -> Void
        init(onTrigger: @escaping () -> Void) { self.onTrigger = onTrigger }
        @objc func handle(_ g: UILongPressGestureRecognizer) {
            if g.state == .began { onTrigger() }
        }
    }
}

/// Companion view: only "claims" a hit when ≥2 touches are present.
/// Lets the gesture recognizer above see the multi-touch event while
/// single-finger touches fall through to the canvas.
private final class TwoFingerPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let touches = event?.allTouches, touches.count >= 2 else { return nil }
        return super.hitTest(point, with: event)
    }
}

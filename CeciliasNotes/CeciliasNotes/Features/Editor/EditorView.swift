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
    @Environment(\.theme) private var theme

    @State private var canvasFrame: CGRect = .zero
    @State private var canUndo: Bool = false
    @State private var canRedo: Bool = false
    @State private var undoTimer: Timer?
    @State private var isShowingCoverPicker: Bool = false
    @State private var isShowingNotebookInfo: Bool = false
    /// State for the "Summarize page" sheet. Earlier this routed
    /// through `ModalPresenter.shared.present(.sheet(...))`, which
    /// attaches at the LibraryView level — the cover-tone editor
    /// `.fullScreenCover` outranks it in iPadOS's "only one sheet at
    /// a time" arbitration, so the sheet only appeared AFTER the
    /// editor dismissed back to home. Backing both this and
    /// `isShowingCoverPicker` with local `.sheet(isPresented:)`
    /// modifiers on `EditorView` puts the presentation INSIDE the
    /// cover (same pattern as `isShowingExportSheet`) so the sheet
    /// appears immediately, on top of the editor where the user
    /// expects it.
    @State private var isShowingSummarizeSheet: Bool = false
    @State private var isShowingAskAboutSheet: Bool = false
    /// Queued PDF URL passed in by Library "Import PDF…". Consumed
    /// once on first appear and cleared so a re-render doesn't double
    /// import.
    @State private var pendingImportPDFURL: URL?
    /// Search-result deep link — opens the notebook scrolled to the
    /// page this id belongs to. Cleared after the first scroll.
    @State private var pendingDeepLinkPageId: UUID?

    init(
        notebook: Notebook,
        importPDFURL: URL? = nil,
        deepLinkPageId: UUID? = nil,
        onDismiss: @escaping () -> Void
    ) {
        // Pass the user's current theme so the editor's default ink colour
        // tracks Default vs Midnight. Pre-Phase-B this parameter was
        // omitted and the editor always used `.light` regardless of the
        // user's theme choice.
        _viewModel = StateObject(wrappedValue: EditorViewModel(
            notebook: notebook,
            theme: ThemeManager.shared.current
        ))
        self.onDismiss = onDismiss
        _pendingImportPDFURL   = State(initialValue: importPDFURL)
        _pendingDeepLinkPageId = State(initialValue: deepLinkPageId)
    }

    var body: some View {
        ZStack {
            editorBody

            // Opt the entire editor out of SwiftUI's automatic
            // keyboard-avoidance reflow. The editor manages keyboard
            // space manually (`keyboardVisibleHeight`) and the canvas
            // already ignores the safe area; without this the root
            // layout shifts up when the keyboard shows and the window
            // background bleeds through the bottom gap as a white
            // underlay sized to the keyboard frame.

            // Step 6: floating recording controls overlay — always
            // mounted, internally hides when no recording is in
            // flight. Sits above the page content but below modal
            // sheets (zIndex 150 < 200 reserved for legacy lecture
            // overlay which is now gone).
            FloatingRecordingControls()
                .allowsHitTesting(RecordingSession.shared.state.isRecording)
                .zIndex(150)
        }
        // Tapping the floating recording timer scrolls the canvas
        // to the page the recording is actively writing to (see
        // `FloatingRecordingControls.timerPill`). Dictation rolls
        // onto continuation pages mid-session, and the user can
        // scroll away while it does — this is the "find where
        // dictation is happening" hook.
        .onReceive(NotificationCenter.default.publisher(for: .recordingScrollToActivePage)) { note in
            guard let pageId = note.userInfo?["pageId"] as? UUID,
                  let idx = viewModel.pages.firstIndex(where: { $0.id == pageId })
            else { return }
            viewModel.currentPageIndex = idx
            viewModel.pendingScrollPageIndex = idx
        }
        .editorPageHandoff(viewModel)
    }

    private var editorBody: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                // 1. Canvas (full screen) + text block overlay (inside scroll/zoom space)
                ContinuousCanvasView(viewModel: viewModel)
                    .ignoresSafeArea()
                    .onAppear { canvasFrame = proxy.frame(in: .global) }
                    .accessibilityLabel(A11y.canvasLabel(strokeCount: viewModel.strokeCount))
                    .accessibilityHint(A11y.canvasHintForCurrentDevice)
                    // Global lasso clear-on-tap: catches taps in the
                    // grey area AROUND the page (the per-page tap-to-
                    // clear inside `LassoOverlayView` only covers the
                    // page itself, so PDF-locked selections that fill
                    // the page have no in-page empty spot to dismiss
                    // them). Simultaneous gesture runs alongside any
                    // child view's own taps so element taps still
                    // reach their handlers; this just adds a "deselect
                    // the lasso" effect to every tap when a selection
                    // is live.
                    .simultaneousGesture(
                        TapGesture().onEnded {
                            // This simultaneous gesture fires for EVERY
                            // tap while a selection is live — including
                            // taps that themselves mutate the selection:
                            // the chrome's delete badge (reads the
                            // selection, then clears it) and cursor-tap
                            // shape selection (sets a new selection).
                            // Clearing unconditionally races both — the
                            // badge saw an empty selection ("trash did
                            // nothing") or the fresh selection was wiped
                            // the moment it appeared.
                            //
                            // Snapshot the mutation counter now, defer a
                            // tick, and clear only if NOTHING else
                            // touched the selection as part of this tap
                            // — i.e. the tap genuinely landed on empty
                            // space.
                            let state = LassoSelectionState.shared
                            let version = state.selectionVersion
                            DispatchQueue.main.async {
                                if state.hasSelection,
                                   state.selectionVersion == version {
                                    state.clear()
                                }
                            }
                        }
                    )

                // Tap-outside-to-dismiss while the title is being
                // renamed. Active ONLY while editing — does not steal
                // canvas touches at any other time. Resigning first
                // responder fires the toolbar's
                // onChange(of: titleFocused) which auto-saves.
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

                // Step 7.2: keyboard-up tap-to-dismiss for text /
                // sticky editing. Gated on the existing
                // `keyboardVisibleHeight` signal so the layer
                // exists ONLY while the keyboard is on screen —
                // doesn't steal canvas/overlay taps at any other
                // time. Sits at zIndex 49 (just under the title-
                // edit layer so they coexist cleanly).
                //
                // In-page taps land here AND on the per-overlay
                // background-tap handler (text + sticky overlays
                // already dismiss on outside-tap); this layer's
                // job is the chrome / toolbar / strip / header
                // area, which the per-overlay handlers can't see.
                // `resignFirstResponder` propagates through
                // `TextEditorRepresentable.updateUIView` /
                // `StickyTextEditor.updateUIView` and the parent
                // overlays' bindings clear their editing state.
                else if viewModel.keyboardVisibleHeight > 0 {
                    Color.clear
                        .contentShape(Rectangle())
                        .ignoresSafeArea()
                        .onTapGesture {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                        .zIndex(49)
                }

                // 2. Floating tool palette — dims in Focus Mode but stays
                // mounted so re-emerging on exit is instant. Hidden
                // outright on read-only devices since none of the
                // tools (pen, highlighter, lasso, text, image, audio)
                // do anything without mutation rights.
                if !viewModel.isFullScreen
                    && !viewModel.isToolPaletteHidden
                    && DeviceCapabilities.canDraw {
                    ToolPaletteView(
                        viewModel: viewModel,
                        parentSize: proxy.size,
                        safeAreaInsets: proxy.safeAreaInsets
                    )
                    .opacity(viewModel.isFocusMode ? 0.3 : 1.0)
                    .animation(.ceciliasNotesSpring(CeciliasNotesSpring.fade), value: viewModel.isFocusMode)
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
                                .padding(.trailing, CeciliasNotes.Spacing.lg)
                                .padding(.bottom,
                                         viewModel.isShowingPageStrip ? 156 : CeciliasNotes.Spacing.lg)
                        }
                    }
                    .transition(.opacity)
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                }

                // 5. Notebook header — auto-hides on first stroke per the
                // redesigned `HeaderVisibility` state machine. When
                // hidden, only a 3pt cover-tone bar remains at the top
                // of the canvas as the visual return indicator, with a
                // 44pt-tall invisible gesture overlay layered above it
                // — the 3pt bar is too small to tap reliably, so the
                // overlay catches taps and short downward swipes
                // anywhere in the top 44pt.
                //
                // `PKCanvasView` claims gestures on its own surface, so
                // any tap-to-reveal recogniser attached to the canvas
                // never fires. The overlay below sits *above* the canvas
                // in the ZStack and only mounts when the header is
                // hidden, so it doesn't steal taps from header buttons.
                if !viewModel.isFullScreen
                    && !viewModel.headerVisibility.isHeaderVisible {
                    VStack(spacing: 0) {
                        // Cover-tone fills the status-bar zone *and*
                        // the 3pt return-bar sliver in one continuous
                        // band so the chrome reads as the cropped edge
                        // of a hidden header rather than as two stacked
                        // strips.
                        Rectangle()
                            .fill(viewModel.notebook.coverTone.background)
                            .frame(height: proxy.safeAreaInsets.top + 3)
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .top)
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(false)        // visual only

                    VStack(spacing: 0) {
                        topEdgeRevealOverlay
                        Spacer()
                    }
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                }

                if !viewModel.isFullScreen
                    && viewModel.headerVisibility.isHeaderVisible {
                    VStack(spacing: 0) {
                        // Explicit cover-tone band that paints the
                        // status-bar zone in cover tone. Without this,
                        // the ZStack's `inkBackgroundSecondary` shows
                        // through the safe area (near-black `#1C1C1A`
                        // in dark mode) and reads as a separate "system
                        // nav bar" above the editor's cover-tone header.
                        viewModel.notebook.coverTone.background
                            .frame(height: proxy.safeAreaInsets.top)
                            .frame(maxWidth: .infinity)

                        EditorToolbarView(
                            viewModel: viewModel,
                            onBack: {
                                // Lasso undo entries are anchored to
                                // the editor-lifetime LassoUndoAnchor
                                // (not the recycled canvases). Clear
                                // them on exit so a stale entry can't
                                // mutate this notebook's elements from
                                // inside another notebook.
                                viewModel.canvasView?.undoManager?
                                    .removeAllActions(withTarget: LassoUndoAnchor.shared)
                                onDismiss()
                            },
                            onUndo: undo,
                            onRedo: redo,
                            canUndo: canUndo,
                            canRedo: canRedo,
                            onShare: shareNotebook,
                            onTogglePageStrip: togglePageStrip,
                            onMoreMenuExportPDF: exportPDF,
                            onMoreMenuExportMarkdown: exportMarkdown,
                            onMoreMenuFindInNotebook: findInNotebook,
                            onMoreMenuPrint: printNotebook,
                            onMoreMenuDuplicatePage: duplicateCurrentPage,
                            onMoreMenuDeletePage: deleteCurrentPage,
                            onMoreMenuSummarizePage: summarizeCurrentPage,
                            onMoreMenuAskAboutPage: askAboutCurrentPage,
                            onMoreMenuCopyPageAsImage: copyCurrentPageAsImage,
                            onMoreMenuActualSize: resetZoomToActualSize,
                            onMoreMenuPageSettings: showPageSettings,
                            onMoreMenuFullScreen: toggleFullScreen,
                            onMoreMenuNotebookInfo: { isShowingNotebookInfo = true },
                            onMoreMenuInsertMedia: { viewModel.mediaInsertCoordinator.insertPhotos() },
                            onStartVoiceNote: { Task { await viewModel.startVoiceNoteRecording() } },
                            onStartDictation: { Task { await viewModel.startDictationRecording() } },
                            onOpenCoverPicker: { isShowingCoverPicker = true }
                        )
                        .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                    .ignoresSafeArea(edges: .top)
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                    // Sit above the Customise panel's tap-outside
                    // layer (zIndex 73) and the panel itself (74) so
                    // the back chevron is tappable even when the
                    // panel is auto-opened for a fresh notebook —
                    // otherwise the first tap on Back lands on the
                    // dismiss layer and only closes the panel.
                    .zIndex(75)
                }

                // 5y. Customise pill (Item 1) — surfaces top-right for ~5s
                // after a fresh notebook is created. Tap → open the panel.
                // Customise pill hidden on iPhone — the masthead is
                // compact, the toolbar already has the customise
                // button, and the floating pill overlaps the
                // shorter compose surface.
                if viewModel.isCustomisePillVisible
                    && !viewModel.isFullScreen
                    && !viewModel.isFocusMode
                    && !viewModel.isCustomisePanelOpen
                    && !DeviceCapabilities.isPhoneIdiom {
                    VStack {
                        HStack {
                            Spacer()
                            CustomisePill(
                                onTap:     { viewModel.openCustomisePanel() },
                                onDismiss: { viewModel.dismissCustomisePill() }
                            )
                            .padding(.trailing, CeciliasNotes.Spacing.md)
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
                            withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                                viewModel.closeCustomisePanel()
                            }
                        }
                        .zIndex(73)

                    VStack {
                        CustomisePanel(viewModel: viewModel)
                            .padding(.top, proxy.safeAreaInsets.top + 56) // below toolbar (matches EditorToolbarView.toolbarHeight)
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
                            HStack(spacing: CeciliasNotes.Spacing.xs) {
                                Image(systemName: "arrow.uturn.backward")
                                    .font(.ceciliasNotesSubhead)
                                    .fontWeight(.semibold)
                                Text("Undo Shape")
                                    .font(.ceciliasNotesSubhead)
                                    .fontWeight(.semibold)
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, CeciliasNotes.Spacing.md)
                            .padding(.vertical, 8)
                            .background(
                                Capsule()
                                    .fill(theme.accent)
                                    .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
                            )
                        }
                        .buttonStyle(.ceciliasNotesPressable)
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
                                HStack(spacing: CeciliasNotes.Spacing.xs) {
                                    Image(systemName: "xmark")
                                        .font(.ceciliasNotesCaption)
                                    Text("Exit Focus")
                                        .font(.ceciliasNotesCaption)
                                }
                                .foregroundColor(theme.foreground)
                                .padding(.horizontal, CeciliasNotes.Spacing.sm)
                                .padding(.vertical, CeciliasNotes.Spacing.xs)
                                .background(
                                    Capsule()
                                        .fill(theme.surfaceElevated.opacity(0.85))
                                )
                            }
                            .buttonStyle(.ceciliasNotesPressable)
                            .opacity(0.6)
                            .padding(.top, proxy.safeAreaInsets.top + CeciliasNotes.Spacing.sm)
                            .padding(.trailing, CeciliasNotes.Spacing.md)
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
                PencilSqueezeDetector(
                    onSqueezeReleased: { viewModel.handlePencilSqueezeReleased() },
                    onSqueezeBegan:    { viewModel.handlePencilSqueezeBegan() },
                    onSqueezeEndedOrCancelled: { viewModel.handlePencilSqueezeEnded() }
                )
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

                // 6. Standalone back chip — only mounted when the header
                //    is hidden, so the toolbar's own back button claims
                //    the tap whenever the header is up. A frosted
                //    material chip plus a fade/slide transition keep
                //    the swap from the toolbar's chevron feeling abrupt.
                if !viewModel.isFullScreen
                    && !viewModel.headerVisibility.isHeaderVisible {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Button {
                                viewModel.prepareForDismissal()
                                onDismiss()
                            } label: {
                                Image(systemName: "chevron.left")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(theme.foreground)
                                    .frame(width: 36, height: 36)
                                    .background(
                                        Circle()
                                            .fill(.regularMaterial)
                                    )
                            }
                            .buttonStyle(.ceciliasNotesPressable)
                            .padding(.leading, CeciliasNotes.Spacing.md)
                            .padding(.top, CeciliasNotes.Spacing.sm)
                            .accessibilityLabel("Back")

                            Spacer()
                        }
                        Spacer()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .opacity(viewModel.isFocusMode ? 0 : 1)
                    .allowsHitTesting(!viewModel.isFocusMode)
                    // Same zIndex story as the toolbar — must sit
                    // above the Customise panel's tap-outside layer
                    // so the back chip works when the panel is open.
                    .zIndex(75)
                }

                // Full-screen exit pill
                //
                // Earlier this was a screen-filling `Color.clear` with
                // an `.onTapGesture` — which absorbed every touch in
                // the editor (the `.contentShape(Rectangle())` was
                // hit-test-active everywhere, but the only gesture
                // wired to it was `.onTapGesture`, so drags / strokes
                // / pinches landed on a do-nothing view). Net effect:
                // touch went completely dead in fullscreen.
                //
                // Replaced with a small top-trailing pill so:
                //   1. canvas touches pass through everywhere except
                //      the pill's bounds (Pencil + finger drawing
                //      work in fullscreen again), and
                //   2. the exit affordance is *visible* — the
                //      two-finger-double-tap escape hatch was the
                //      only way out, and there's no UI to surface it.
                if viewModel.isFullScreen {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                                    viewModel.isFullScreen = false
                                    viewModel.resetToolbarTimer()
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("exit")
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(theme.foreground)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(.ultraThinMaterial)
                                )
                                .overlay(
                                    Capsule(style: .continuous)
                                        .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Exit fullscreen")
                        }
                        Spacer()
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    // The VStack itself stretches to fill its parent,
                    // but `Color.clear` between the pill and the edges
                    // is NOT hit-testable (only the Button is), so
                    // canvas touches outside the pill pass through.
                    .allowsHitTesting(true)
                    .zIndex(78)
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
                    VStack(spacing: CeciliasNotes.Spacing.sm) {
                        ProgressView(value: viewModel.mediaInsertCoordinator.processingProgress)
                            .tint(.white)
                            .frame(width: 200)
                        Text("Processing…")
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(.white)
                    }
                    .padding(CeciliasNotes.Spacing.lg)
                    .background(theme.surfaceElevated.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.lg, style: .continuous))
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

                // Step 6: V5 `RecordingPanelView` removed — Voice
                // Note recording now renders inline on the page via
                // `AudioElementView.recordingStrip`, and the
                // `FloatingRecordingControls` overlay (mounted at
                // the ZStack root above) carries the global timer +
                // stop button.
            }
            .background(theme.surface.ignoresSafeArea())
        }
        // Suppress any inherited system navigation bar — the cover-tone
        // header is the editor's only top chrome. Without this, an
        // ancestral NavigationSplitView can still surface a system nav
        // bar through `.fullScreenCover` on iPadOS, leaving the title
        // double-rendered (small system style above + heavy cover-tone
        // style below).
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .ignoresSafeArea(.keyboard, edges: .bottom)
        // Phase 5B: editor-internal modals migrated to ModalPresenter.
        // The editor itself is a `.fullScreenCover` from `LibraryView`;
        // sheets presented directly from this view risk SwiftUI's
        // sheet-over-cover collision ("Currently, only presenting a
        // single sheet is supported"). Routing through
        // `ModalPresenter.shared` puts the sheets above the cover via
        // the host modifier on `RootView`. The trigger state (the
        // @State / @Published booleans below) stays so existing
        // callers and the deep-link / header paths don't change; the
        // .onChange handlers translate flag flips into presenter
        // calls and the `onDidDismiss` callback resets the flag on
        // swipe-dismiss.
        // Files / camera / scan pickers present LOCALLY off
        // EditorView — same fix the cover picker got. The previous
        // `ModalPresenter` route attached its sheet at the
        // LibraryView level BEHIND the editor's `.fullScreenCover`,
        // so on device the picker only surfaced after the user
        // dismissed back to the library ("insert media options only
        // open after coming out of the notebook").
        .sheet(item: Binding(
            get: { viewModel.activeMediaSource },
            set: { newValue in
                // Swipe-dismiss lands mid-view-update; defer the
                // @Published clear to avoid AttributeGraph cycles.
                if newValue == nil {
                    Task { @MainActor in viewModel.activeMediaSource = nil }
                } else {
                    viewModel.activeMediaSource = newValue
                }
            }
        )) { source in
            mediaPickerSheet(for: source)
        }
        // The image-attachment import picker is presented from
        // `LibraryViewModel` via the `.imageImportRequested` /
        // `.imageImportCompleted` notification pair — see
        // `ImageImportNotifications.swift`. It deliberately bypasses
        // the editor entirely so the editor's cover doesn't share a
        // presentation lineage with the picker.
        .sheet(isPresented: Binding(
            get: { viewModel.isShowingAudioFilePicker },
            set: { newValue in
                if !newValue {
                    Task { @MainActor in viewModel.isShowingAudioFilePicker = false }
                }
            }
        )) {
            AudioFilePicker(viewModel: viewModel) {
                Task { @MainActor in viewModel.isShowingAudioFilePicker = false }
            }
        }
        // Cover picker — local `.sheet` (NOT `ModalPresenter`) so it
        // presents on top of the editor immediately. The previous
        // `ModalPresenter` route attached at the LibraryView level
        // behind the editor's `.fullScreenCover`, so the sheet only
        // surfaced after the user dismissed back to home.
        .sheet(isPresented: $isShowingCoverPicker) {
            CoverTonePickerView(notebook: viewModel.notebook) {
                isShowingCoverPicker = false
            }
            .presentationDetents([.medium])
        }
        .sheet(isPresented: $isShowingNotebookInfo) {
            NotebookOriginInfoSheet(notebook: viewModel.notebook)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
        // Summarize page — same in-editor presentation route as the
        // cover picker, for the same reason.
        .sheet(isPresented: $isShowingSummarizeSheet) {
            SummarizePageView(
                page: viewModel.currentPage,
                notebookTitle: viewModel.notebook.title,
                notebookId: viewModel.notebook.id,
                onDismiss: { isShowingSummarizeSheet = false }
            )
        }
        .sheet(isPresented: $isShowingAskAboutSheet) {
            AskAboutPageView(
                page: viewModel.currentPage,
                notebookTitle: viewModel.notebook.title,
                onDismiss: { isShowingAskAboutSheet = false }
            )
        }
        // Export sheet is presented LOCALLY off EditorView rather
        // than through `ModalPresenter`. `ModalPresenter`'s sheet is
        // attached at the same SwiftUI level as the editor's own
        // `.fullScreenCover` (both modifiers on `LibraryView`); when
        // both try to present, iPadOS rejects the second with
        // "Currently, only presenting a single sheet is supported"
        // and the export sheet flashes in then disappears. Mounting
        // the export sheet on EditorView puts it INSIDE the cover,
        // not in competition with it.
        .sheet(isPresented: $viewModel.isShowingInNotebookSearch) {
            InNotebookSearchView(notebook: viewModel.notebook) { pageId in
                if let idx = viewModel.pages.firstIndex(where: { $0.id == pageId }) {
                    viewModel.goToPage(index: idx)
                }
            } onDismiss: {
                viewModel.isShowingInNotebookSearch = false
            }
        }
        .sheet(isPresented: $viewModel.isShowingExportSheet) {
            #if DEBUG
            let _ = dlog("[Share] viewBuilder invoked — about to render ExportOptionsView")
            #endif
            ExportOptionsView(
                notebook: viewModel.notebook,
                pages: viewModel.pages,
                currentIndex: viewModel.currentPageIndex,
                initialFormat: viewModel.exportDeliveryFormat
            ) {
                viewModel.isShowingExportSheet = false
            }
        }
        .statusBarHidden(viewModel.isFullScreen || viewModel.isFocusMode)
        .persistentSystemOverlays(viewModel.isFocusMode ? .hidden : .automatic)
        .onAppear {
            startUndoStateTimer()
            // All published-property writes below are deferred to the
            // next runloop tick. `.onAppear` can land inside the same
            // view-update transaction that's still resolving the
            // current body, and synchronous `@Published` mutations
            // there fire SwiftUI's "Publishing changes from within
            // view updates is not allowed" warning. Deferring with
            // `DispatchQueue.main.async` clears the transaction.
            DispatchQueue.main.async {
                // Library "Share as PDF…" deep-link.
                if deepLink.pendingExport {
                    deepLink.pendingExport = false
                    viewModel.isShowingExportSheet = true
                }
                // "+ new notebook → editor" hand-off — auto-open the
                // Customise panel + request name-field focus. Consumed
                // via the one-shot registry so re-opening doesn't repeat.
                if NewNotebookCustomiseTrigger.consume(viewModel.notebook.id) {
                    viewModel.pendingCustomiseNameFocus = true
                    // The auto-opened panel IS the customise moment —
                    // mark the pill satisfied so it can't resurface
                    // when the user closes the panel and this
                    // notebook re-appears within the 30s freshness
                    // window.
                    viewModel.markCustomisePillSatisfied()
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                        viewModel.isCustomisePanelOpen = true
                    }
                } else {
                    // Surface the floating Customise pill iff this is a
                    // freshly-created notebook we haven't pilled this session.
                    withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                        viewModel.markCustomisePillIfFresh()
                    }
                }
                // Search deep-link: scroll to the result's page index
                // (pages may have reordered since indexing).
                if let pageId = pendingDeepLinkPageId,
                   let idx = viewModel.pages.firstIndex(where: { $0.id == pageId }) {
                    pendingDeepLinkPageId = nil
                    viewModel.pendingScrollPageIndex = idx
                }
            }
        }
        .task {
            // Library "Import PDF…" hand-off: rasterise each PDF page
            // onto its own notebook page using the editor's existing
            // media-insert pipeline. Consumed once and cleared so a
            // view re-render doesn't double-import.
            if let url = pendingImportPDFURL {
                pendingImportPDFURL = nil
                let coordinator = viewModel.mediaInsertCoordinator
                let didStart = url.startAccessingSecurityScopedResource()
                await coordinator.handlePickedFileURLs([url])
                if didStart { url.stopAccessingSecurityScopedResource() }
            }
        }
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth), value: viewModel.isCustomisePanelOpen)
        .animation(.ceciliasNotesSpring(CeciliasNotesSpring.fade),   value: viewModel.isCustomisePillVisible)
        .onDisappear {
            #if DEBUG
            dlog("[ImageInsert] 3. EditorView.onDisappear fired — editor is being torn down")
            #endif
            undoTimer?.invalidate()
            undoTimer = nil
            viewModel.prepareForDismissal()
        }
        // Notification-driven @Published writes are deferred to the
        // next runloop tick. Keyboard show/hide and ⌘W close fire
        // through the same observer queue as the active view-update
        // transaction, and a synchronous `viewModel.foo = …` here
        // produces the "Publishing changes from within view updates"
        // warning. Repeated occurrences during keyboard animations
        // were the leading suspect for the SIGKILL crash.
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { note in
            Task { @MainActor in handleKeyboardWillShow(note) }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { _ in
            Task { @MainActor in
                withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
                    viewModel.keyboardVisibleHeight = 0
                }
            }
        }
        // ⌘W / ⌘⇧E / ⌘P / ⌘N / ⌘F come from the WindowGroup .commands modifier
        // (see CeciliasNotesCommands) and arrive as notifications.
        .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandCloseNotebook)) { _ in
            Task { @MainActor in
                viewModel.prepareForDismissal()
                onDismiss()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandExport)) { _ in
            exportPDF()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandFindInNotebook)) { _ in
            viewModel.isShowingInNotebookSearch = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ceciliasNotesCommandPrint)) { _ in
            printNotebook()
        }
        // Per-screen shortcuts that should be disabled outside the editor stay
        // as hidden Buttons here. These don't appear in CeciliasNotesCommands deliberately.
        .background(
            VStack(spacing: 0) {
                Button("Undo")     { undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!canUndo)
                Button("Redo")     { redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!canRedo)
                // ⌘← / ⌘→ scroll one viewport-height up / down in the
                // continuous-scroll canvas. The previous binding swapped
                // pages 1:1 — no longer needed now that all pages are
                // visible at once. Page-strip tap still navigates to a
                // specific page.
                Button("Scroll Up")   { scrollByViewportHeight(direction: -1) }
                    .keyboardShortcut(.leftArrow,  modifiers: .command)
                Button("Scroll Down") { scrollByViewportHeight(direction:  1) }
                    .keyboardShortcut(.rightArrow, modifiers: .command)
                Button("Close Editor")  { onDismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Toggle Toolbar") { viewModel.resetToolbarTimer() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Focus Mode") { viewModel.toggleFocusMode() }
                    .keyboardShortcut("f", modifiers: [.command, .control])
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
            NotificationCenter.default.publisher(for: .ceciliasNotesCanvasShouldPanTo)
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

    // MARK: Continuous-scroll keyboard navigation

    /// Walk up the active canvas's view hierarchy to find the outer
    /// UIScrollView, then scroll one viewport height up / down. Direction
    /// is `-1` for up, `+1` for down. No-op if the scroll view can't be
    /// found (e.g. the canvas hasn't mounted yet).
    private func scrollByViewportHeight(direction: CGFloat) {
        var v: UIView? = viewModel.canvasView
        while let candidate = v {
            if let scrollView = candidate as? UIScrollView,
               scrollView.contentSize.height > scrollView.bounds.height {
                let target = scrollView.contentOffset.y
                    + direction * scrollView.bounds.height * 0.92
                let maxY = scrollView.contentSize.height
                    - scrollView.bounds.height
                    + scrollView.contentInset.bottom
                let minY = -scrollView.contentInset.top
                let clamped = Swift.min(maxY, Swift.max(minY, target))
                scrollView.setContentOffset(
                    CGPoint(x: scrollView.contentOffset.x, y: clamped),
                    animated: true
                )
                return
            }
            v = candidate.superview
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
        let mgr = viewModel.canvasView?.undoManager
        mgr?.undo()
        // The 200ms state poll leaves both buttons stale right after
        // a tap — a quick undo-then-redo landed on a still-disabled
        // redo button and silently no-oped, which read as "redo
        // doesn't work" (and rapid multi-undo as "undo sometimes
        // doesn't work"). Refresh synchronously so the very next tap
        // sees the truth.
        canUndo = mgr?.canUndo ?? false
        canRedo = mgr?.canRedo ?? false
        viewModel.scheduleAutosave()
        viewModel.pulseInteraction(.undoRedo)
    }

    private func redo() {
        let mgr = viewModel.canvasView?.undoManager
        mgr?.redo()
        canUndo = mgr?.canUndo ?? false
        canRedo = mgr?.canRedo ?? false
        viewModel.scheduleAutosave()
        viewModel.pulseInteraction(.undoRedo)
    }

    private func togglePageStrip() {
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
            viewModel.isShowingPageStrip.toggle()
        }
        viewModel.resetToolbarTimer()
    }

    private func toggleFullScreen() {
        withAnimation(.ceciliasNotesSpring(CeciliasNotesSpring.smooth)) {
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

    /// Present the AI "Summarize this page" sheet for the current
    /// page. Routed through `ModalPresenter` like the export sheet —
    /// the editor is itself a full-screen cover, so an inline
    /// `.sheet` from here would silently fail to present.
    private func summarizeCurrentPage() {
        isShowingSummarizeSheet = true
    }

    private func askAboutCurrentPage() {
        isShowingAskAboutSheet = true
    }

    private func copyCurrentPageAsImage() {
        CopyPageService.copyPage(viewModel.currentPage)
    }

    private func resetZoomToActualSize() {
        viewModel.zoomScale = 1.0
        viewModel.resetToolbarTimer()
    }

    // MARK: Top-edge gesture overlay (header reveal)

    /// Invisible 44pt-tall surface that catches taps and short downward
    /// swipes when the header is hidden, calling
    /// `viewModel.revealHeaderManually()`. The 3pt visible bar is the
    /// indicator; this is the *target*. Without `.contentShape`, an
    /// empty `Color.clear` view is not hit-testable.
    private var topEdgeRevealOverlay: some View {
        Color.clear
            .frame(height: 44)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.revealHeaderManually()
            }
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { value in
                        guard value.translation.height > 20 else { return }
                        viewModel.revealHeaderManually()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Show header")
            .accessibilityAddTraits(.isButton)
    }

    private func showPageSettings() {
        // Stage 5+ — present a sheet with template/size pickers for current page
    }

    private func exportPDF() {
        viewModel.exportDeliveryFormat = .pdf
        viewModel.isShowingExportSheet = true
    }

    private func exportMarkdown() {
        viewModel.exportDeliveryFormat = .markdown
        viewModel.isShowingExportSheet = true
    }

    private func findInNotebook() {
        viewModel.isShowingInNotebookSearch = true
    }

    /// Routes through the export sheet so the user gets a real PDF + Share button
    /// (rather than sharing just the title string, which the previous stub did).
    private func shareNotebook() {
        #if DEBUG
        dlog("[Share] shareNotebook() called; isShowingExportSheet was=\(viewModel.isShowingExportSheet)")
        #endif
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
                // UIKit delegate fires synchronously inside the SwiftUI
                // dismiss path; defer the @Published mutation to the
                // next runloop tick to break the "publishing changes
                // from within view updates" cycle.
                Task { @MainActor in viewModel.activeMediaSource = nil }
            }
        case .scan:
            DocumentScannerPicker { scan in
                Task { await coord.handleScannedDocument(scan) }
            } onCancel: {
                Task { @MainActor in viewModel.activeMediaSource = nil }
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

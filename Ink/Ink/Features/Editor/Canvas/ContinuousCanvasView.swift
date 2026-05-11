import Combine
import PencilKit
import SwiftUI
import UIKit

/// Continuous-scroll writing surface (Item 2, Phase 1).
///
/// Replaces the single-canvas `CanvasContainerView`. Lays every page out
/// vertically inside one big `UIScrollView`, with `Ink.Spacing.lg` gaps
/// (~24pt) of editor background between pages. Pinch-zoom zooms the
/// entire stack together so all pages scale as one document.
///
/// Memory invariants
///   • `PageRenderer` (lightweight Core Graphics view) is mounted for
///     every page — needed to draw paper colour + template even when
///     offscreen, so a fast scroll never reveals an empty void.
///   • `PKCanvasView` (heavy — Metal-backed) is mounted lazily only for
///     pages whose frame intersects the *warm band* (visible viewport
///     ± one viewport height). Outside that band the canvas is torn
///     down after a synchronous save flush.
///
/// Active page tracking
///   The page whose vertical centre is closest to the viewport centre
///   is the "active" page. We update `viewModel.currentPageIndex` and
///   point `viewModel.canvasView` at that page's PKCanvasView so existing
///   features (toolbar undo manager, shape recognition, text/media/audio
///   overlays) keep working unchanged.
///
/// Auto-add page
///   Triggered when the user *finishes a stroke on the last page whose
///   geometry extends into the bottom half of that page*. Pure scrolling
///   (no drawing) never appends pages — that prevents the runaway
///   "every scroll-to-bottom adds a page" behaviour. The bottom-half
///   gate keeps short top-of-page strokes from adding pages too. Gated
///   by the `ink.newpage.autoAdd` setting and throttled to once per
///   second so a flurry of strokes can't add a stack at once.
///
/// Phase 1 deferral
///   Text-block / media-attachment / audio-annotation overlays live in
///   a single "floating overlay layer" that snaps to the active page's
///   frame on each active-page change. They render only on the active
///   page. Per-page overlay rendering is Phase 2.
struct ContinuousCanvasView: UIViewRepresentable {

    @ObservedObject var viewModel: EditorViewModel
    @AppStorage("ink.canvas.fingerDrawingEnabled") private var fingerDrawingEnabled: Bool = false

    private let pageGap: CGFloat              = 24
    private let warmBandPaddingFactor: CGFloat = 1.0
    private let autoAddCooldown: TimeInterval = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel,
                    fingerDrawingEnabled: fingerDrawingEnabled,
                    pageGap: pageGap,
                    warmBandPaddingFactor: warmBandPaddingFactor,
                    autoAddCooldown: autoAddCooldown)
    }

    // MARK: makeUIView

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.backgroundColor = .inkCanvasBackground
        host.isUserInteractionEnabled = true

        let scrollView = UIScrollView(frame: host.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.showsVerticalScrollIndicator   = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDrawingEnabled ? 2 : 1
        host.addSubview(scrollView)

        // Single content view holds every page-host stacked vertically.
        // viewForZooming returns this so pinch zooms the whole document.
        let contentView = UIView(frame: .zero)
        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        scrollView.addSubview(contentView)

        // Floating overlay layer — hosts the audio-annotation pins for
        // the active page. `AudioPassthroughContainer` lets empty-area
        // taps fall through to PKCanvasView while still routing taps
        // on actual SwiftUI pin views. Re-parented to the active page
        // host as the user scrolls.
        let overlayLayer = AudioPassthroughContainer(frame: .zero)
        overlayLayer.backgroundColor = .clear
        overlayLayer.isUserInteractionEnabled = true
        contentView.addSubview(overlayLayer)

        // Audio pin overlays are mounted PER-PAGE inside each
        // `PageRenderer` below — the single global overlay that
        // used to live here re-parented onto the active page via
        // `installOverlayLayerIntoActivePage`, which lagged behind
        // the scroll and made pins appear to drift relative to
        // their pages. Per-page mounting eliminates the lag: each
        // overlay is a child of its page renderer and scrolls with
        // it mechanically.

        // Sticky notes — second SwiftUI overlay sharing the same
        // passthrough container. The view itself toggles its
        // interactive surface (full-bleed placement layer vs.
        // marker-only taps) based on `viewModel.selectedTool`.
        let stickyHost = UIHostingController(
            rootView: StickyNotesOverlayView(viewModel: viewModel)
        )
        stickyHost.view.backgroundColor = .clear
        stickyHost.view.translatesAutoresizingMaskIntoConstraints = false
        overlayLayer.addSubview(stickyHost.view)
        NSLayoutConstraint.activate([
            stickyHost.view.topAnchor.constraint(equalTo: overlayLayer.topAnchor),
            stickyHost.view.leadingAnchor.constraint(equalTo: overlayLayer.leadingAnchor),
            stickyHost.view.trailingAnchor.constraint(equalTo: overlayLayer.trailingAnchor),
            stickyHost.view.bottomAnchor.constraint(equalTo: overlayLayer.bottomAnchor),
        ])

        context.coordinator.host             = host
        context.coordinator.scrollView       = scrollView
        context.coordinator.contentView      = contentView
        context.coordinator.overlayLayer     = overlayLayer
        // `audioPinsHost` is intentionally left nil — audio pin
        // overlays now mount per-page inside each `PageRenderer`
        // (see the page-mount loop below). The coordinator's
        // `audioPinsHost` slot stays in the model for legacy
        // diagnostics but isn't populated.
        context.coordinator.stickyNotesHost  = stickyHost

        // Two-finger double tap → 100% zoom. The page-by-page two-finger
        // *swipe* navigation is intentionally absent — continuous scroll
        // makes it redundant, and freeing two-finger gestures unblocks the
        // canvas in Focus Mode for further extensions.
        let twoFingerDoubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerDoubleTap)
        )
        twoFingerDoubleTap.numberOfTapsRequired = 2
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(twoFingerDoubleTap)

        // Single-finger double tap → fit-to-width.
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(doubleTap)

        // Defer initial layout to the next runloop so SwiftUI's frame
        // assignment has settled.
        DispatchQueue.main.async {
            context.coordinator.rebuildPageHosts()
            context.coordinator.scrollToPage(viewModel.currentPageIndex, animated: false)
            context.coordinator.installOverlayLayerIntoActivePage(animated: false)
            context.coordinator.installFlushHandler()
        }
        return host
    }

    // MARK: updateUIView

    func updateUIView(_ host: UIView, context: Context) {
        let coord = context.coordinator
        guard let scrollView = coord.scrollView else { return }

        coord.fingerDrawingEnabled = fingerDrawingEnabled

        // Pan gesture touch count tracks finger-drawing setting.
        let desiredTouches = fingerDrawingEnabled ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != desiredTouches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = desiredTouches
        }

        // Drawing policy + tool propagate to every mounted canvas. Cheap
        // — typically 3–5 canvases live at once.
        coord.applyDrawingPolicyToAll(fingerDraws: fingerDrawingEnabled)
        coord.applyToolToAll(viewModel.selectedTool)

        // Page list change (autoAdd appended a page, or first run).
        coord.rebuildPageHostsIfNeeded()

        // External "scroll to page" requests from the page strip / keyboard.
        // Clear conditionally so a second tap landing while we're still
        // dispatched doesn't clobber the newer request.
        if let target = viewModel.pendingScrollPageIndex {
            coord.scrollToPage(target, animated: true)
            DispatchQueue.main.async {
                if viewModel.pendingScrollPageIndex == target {
                    viewModel.pendingScrollPageIndex = nil
                }
            }
        }

        // External zoom (minimap, etc.)
        if abs(scrollView.zoomScale - viewModel.zoomScale) > 0.001 {
            if !coord.suppressZoomUpdate {
                coord.suppressZoomUpdate = true
                scrollView.setZoomScale(viewModel.zoomScale, animated: false)
                coord.suppressZoomUpdate = false
            }
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject,
                             UIScrollViewDelegate,
                             PKCanvasViewDelegate,
                             UIPencilInteractionDelegate,
                             UIGestureRecognizerDelegate {

        let viewModel: EditorViewModel
        var fingerDrawingEnabled: Bool

        private let pageGap: CGFloat
        private let warmBandPaddingFactor: CGFloat
        private let autoAddCooldown: TimeInterval

        weak var host:         UIView?
        weak var scrollView:   UIScrollView?
        weak var contentView:  UIView?
        weak var overlayLayer: UIView?
        // Strong ref — UIHostingController keeps the SwiftUI overlay
        // alive. Released when the coordinator deinits (i.e. when the
        // editor view is dismissed).
        var audioPinsHost: UIHostingController<AudioAnnotationPinsOverlayView>?
        /// Strong ref to the sticky-notes hosting controller — same
        /// pattern as `audioPinsHost`. Released when the coordinator
        /// deinits.
        var stickyNotesHost: UIHostingController<StickyNotesOverlayView>?

        struct PageHostState {
            let pageId: UUID
            var frame: CGRect              // in contentView coords
            let renderer: PageRenderer     // always mounted (paper bg)
            /// SwiftUI `TemplatePatternView` mounted inside the
            /// renderer to paint the page's template pattern. Kept as
            /// a strong ref alongside the renderer so the controller
            /// outlives `mountCanvas` / `unmountCanvas` cycles.
            var templateHost: UIHostingController<TemplatePatternView>
            var template: PageTemplate
            var canvasView: PKCanvasView?  // lazy-mounted when in warm band
            var saveTask: Task<Void, Never>?
            var isDirty: Bool = false
        }

        var hosts: [PageHostState] = []
        private var lastSnapshot: [UUID] = []     // page id list, for diffing
        private var lastActivePageId: UUID?
        var suppressZoomUpdate = false
        private var suppressActivePageUpdates = false
        private var lastAutoAddDate: Date = .distantPast
        private var isStrokeInProgress = false
        var appliedTool: InkTool?

        init(viewModel: EditorViewModel,
             fingerDrawingEnabled: Bool,
             pageGap: CGFloat,
             warmBandPaddingFactor: CGFloat,
             autoAddCooldown: TimeInterval) {
            self.viewModel = viewModel
            self.fingerDrawingEnabled = fingerDrawingEnabled
            self.pageGap = pageGap
            self.warmBandPaddingFactor = warmBandPaddingFactor
            self.autoAddCooldown = autoAddCooldown
        }

        deinit {
            // Pencil double-tap and other interactions cleaned up when
            // their host views are released. Save tasks are cooperative
            // and will see Task.isCancelled on the next tick.
        }

        // MARK: Page hosts — diff + (re)build

        func rebuildPageHostsIfNeeded() {
            let snapshot = viewModel.pages.map(\.id)
            guard snapshot != lastSnapshot else {
                // Page list shape unchanged, but page metadata (size /
                // template) may have changed via Customise panel.
                applyPageMetadataChanges()
                return
            }
            // Phase 1 simplification: rebuild from scratch on any list
            // change. The cost is 1× PKDrawing reload per page in the warm
            // band, which dominates and is independent of the rebuild.
            // Auto-add appends one page, so this stays cheap in practice.
            rebuildPageHosts()
        }

        func rebuildPageHosts() {
            guard let contentView else { return }
            tearDownAllHosts()
            var y: CGFloat = 0
            // Use the widest page as the content width so a mixed-size
            // notebook (e.g. A4 + Letter) stays centred without horizontal
            // jitter while scrolling.
            let pages   = viewModel.pages
            let maxW    = pages.map { $0.pageSize.pointSize.width }.max() ?? PageSize.a4.pointSize.width
            for page in pages {
                let baseSize = page.pageSize.pointSize
                let h = effectiveHeight(for: page)
                let frame = CGRect(
                    x: (maxW - baseSize.width) / 2,
                    y: y,
                    width: baseSize.width,
                    height: h
                )
                let renderer = PageRenderer(pageSize: page.pageSize)
                renderer.frame = frame

                // PDF-backed pages draw the source PDF page on top of
                // the paper; their template overlay is hidden (a PDF
                // background and a template pattern shouldn't stack).
                if let pdfIndex = page.pdfPageIndex,
                   let sourceURL = viewModel.notebook.sourcePDFURL {
                    renderer.updatePDFBacking(sourceURL: sourceURL, pageIndex: pdfIndex)
                    // Wire the page id so the renderer can paint
                    // `PDFTextAnnotationStore` records (highlights,
                    // underlines, strikethroughs) on top of the PDF
                    // background. Reactive to store changes via the
                    // observer set up inside `attachPageId`.
                    renderer.attachPageId(page.id)
                    // Subscribe to the editor's pulse signal. Every
                    // PDF-backed renderer observes the same
                    // publisher; only the renderer whose page holds
                    // the matching record actually animates.
                    renderer.attachPulseSource(viewModel.$pulsingAnnotationId)
                }

                // Mount the SwiftUI template pattern inside the
                // renderer so paper colour (UIKit, theme-aware) sits
                // behind the pattern (SwiftUI Canvas, theme-agnostic).
                let templateHost = UIHostingController(
                    rootView: TemplatePatternView(template: page.backgroundTemplate)
                )
                templateHost.view.backgroundColor = .clear
                templateHost.view.isUserInteractionEnabled = false
                templateHost.view.isHidden = page.pdfPageIndex != nil
                templateHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(templateHost.view)
                NSLayoutConstraint.activate([
                    templateHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    templateHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    templateHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    templateHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])

                // Image attachments layer — sits ABOVE the
                // background (template / PDF) and BELOW the
                // PencilKit canvas. The hierarchy is non-negotiable
                // per the architecture rule: PKCanvasView is always
                // the topmost interactive layer so handwriting
                // overwrites images cleanly.
                let imagesHost = UIHostingController(
                    rootView: ImageAttachmentsView(
                        viewModel: viewModel,
                        pageId: page.id,
                        pageSize: CGSize(width: baseSize.width, height: h)
                    )
                )
                imagesHost.view.backgroundColor = .clear
                imagesHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(imagesHost.view)
                NSLayoutConstraint.activate([
                    imagesHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    imagesHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    imagesHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    imagesHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])

                // Audio pin overlay — per-page, scoped to this
                // page's id. Replaces the legacy single-overlay
                // design that re-parented onto the active page and
                // caused pins to drift on scroll. Lives in the
                // page renderer's coordinate space so positions
                // need no scroll-offset math.
                let audioPinsHost = UIHostingController(
                    rootView: AudioAnnotationPinsOverlayView(
                        viewModel: viewModel,
                        pageId: page.id
                    )
                )
                audioPinsHost.view.backgroundColor = .clear
                audioPinsHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(audioPinsHost.view)
                NSLayoutConstraint.activate([
                    audioPinsHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    audioPinsHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    audioPinsHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    audioPinsHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])

                // Lecture-block overlay — per-page, renders the
                // proper `LectureBlockView` (header / summary /
                // transcript toggle / playback) in place of any
                // `lecture:<uuid>` TextBlock on this page. The
                // legacy routing path via `TextBlockOverlayView`
                // is not mounted in the canvas hierarchy, so this
                // overlay is the only render site for lecture
                // blocks until that view is wired in.
                let lectureHost = UIHostingController(
                    rootView: LectureBlocksOverlayView(
                        viewModel: viewModel,
                        pageId: page.id,
                        pageSize: CGSize(width: baseSize.width, height: h)
                    )
                )
                lectureHost.view.backgroundColor = .clear
                lectureHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(lectureHost.view)
                NSLayoutConstraint.activate([
                    lectureHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    lectureHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    lectureHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    lectureHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])

                contentView.addSubview(renderer)
                hosts.append(PageHostState(
                    pageId:       page.id,
                    frame:        frame,
                    renderer:     renderer,
                    templateHost: templateHost,
                    template:     page.backgroundTemplate
                ))
                y += h + pageGap
            }
            // Total content height excludes the trailing gap.
            let height = max(0, y - pageGap)
            updateContentSize(width: maxW, height: height)
            lastSnapshot = pages.map(\.id)

            // Mount canvases for the warm band straight away so the user
            // doesn't see a paper-only flash when entering the editor.
            // Active-page detection deliberately deferred: the first
            // rebuild lands BEFORE the initial scrollToPage moves the
            // viewport off (0, 0), so we'd otherwise reset the resumed
            // page back to page 0.
            updateCanvasMembership(force: true)
        }

        private func tearDownAllHosts() {
            for i in hosts.indices {
                if hosts[i].isDirty,
                   let canvas = hosts[i].canvasView,
                   let page   = page(for: hosts[i].pageId) {
                    viewModel.savePage(page, drawing: canvas.drawing)
                }
                hosts[i].saveTask?.cancel()
                hosts[i].canvasView?.removeFromSuperview()
                hosts[i].renderer.removeFromSuperview()
            }
            hosts.removeAll()
        }

        /// Refresh `PageRenderer.template` / `PageRenderer.pageSize` /
        /// `Page.extraHeight` when a page's metadata changed without the
        /// page list itself changing. Customise panel mutations and
        /// auto-extend-last-page mutations both land here. A change to
        /// `pageSize` or `extraHeight` reshapes the layout, so we trigger
        /// a full rebuild of host frames + content size in that case.
        private func applyPageMetadataChanges() {
            var needsLayoutRebuild = false
            for i in hosts.indices {
                guard let page = page(for: hosts[i].pageId) else { continue }
                let templateChanged   = hosts[i].template != page.backgroundTemplate
                let pageSizeChanged   = hosts[i].renderer.pageSize != page.pageSize
                let effective         = effectiveHeight(for: page)
                let extraHeightChanged = abs(hosts[i].frame.height - effective) > 0.5
                if pageSizeChanged {
                    hosts[i].renderer.update(pageSize: page.pageSize)
                }
                if templateChanged {
                    hosts[i].template = page.backgroundTemplate
                    hosts[i].templateHost.rootView =
                        TemplatePatternView(template: page.backgroundTemplate)
                }
                if pageSizeChanged || extraHeightChanged {
                    needsLayoutRebuild = true
                }
            }
            if needsLayoutRebuild {
                relayoutHosts()
            }
        }

        /// Effective rendered height for a page = base size + auto-grow
        /// extension. The extension is stored sidecar in
        /// `PageExtraHeightStore` keyed by page UUID — see the comment
        /// in InkSchemas.swift for why it's not a SwiftData column.
        private func effectiveHeight(for page: Page) -> CGFloat {
            page.pageSize.pointSize.height
                + PageExtraHeightStore.extraHeight(forPageId: page.id)
        }

        /// Recompute every host's frame in place (without tearing down
        /// canvases), then update the scroll view's content size. Used
        /// when the last page auto-grows or when the user changes a
        /// page's size via the Customise panel.
        private func relayoutHosts() {
            guard let contentView else { return }
            let pages = viewModel.pages
            guard pages.count == hosts.count else {
                // Page list shape changed — fall through to a full rebuild.
                rebuildPageHosts()
                return
            }
            let maxW = pages.map { $0.pageSize.pointSize.width }.max()
                ?? PageSize.a4.pointSize.width
            var y: CGFloat = 0
            for (i, page) in pages.enumerated() {
                let w = page.pageSize.pointSize.width
                let h = effectiveHeight(for: page)
                let frame = CGRect(x: (maxW - w) / 2, y: y, width: w, height: h)
                hosts[i].frame = frame
                hosts[i].renderer.frame = frame
                hosts[i].canvasView?.frame = frame
                y += h + pageGap
            }
            let height = max(0, y - pageGap)
            updateContentSize(width: maxW, height: height)
            // The contentView is a child of the scrollView; updating its
            // own frame is part of `updateContentSize`. Repaint pages.
            for h in hosts { h.renderer.setNeedsDisplay() }
            _ = contentView   // referenced for completeness
        }

        private func updateContentSize(width: CGFloat, height: CGFloat) {
            guard let scrollView, let contentView else { return }
            contentView.frame = CGRect(x: 0, y: 0, width: width, height: height)
            scrollView.contentSize = CGSize(width: width, height: height)
            // Centre horizontally + add half-viewport top/bottom inset so
            // the user can scroll the first/last page to the middle of the
            // viewport (matches Files / Preview conventions).
            let hInset = max(0, (scrollView.bounds.width  - width)  / 2)
            let vInset = max(0, scrollView.bounds.height / 2 - height / 2)
            scrollView.contentInset = UIEdgeInsets(
                top:    Swift.max(scrollView.bounds.height * 0.10, vInset),
                left:   hInset,
                bottom: Swift.max(scrollView.bounds.height * 0.10, vInset),
                right:  hInset
            )
        }

        // MARK: Canvas membership (lazy mount/unmount)

        func updateCanvasMembership(force: Bool = false) {
            guard let scrollView, let contentView else { return }
            let viewportTop    = scrollView.contentOffset.y
            let viewportBottom = viewportTop + scrollView.bounds.height
            let pad = scrollView.bounds.height * warmBandPaddingFactor
            let warmTop    = viewportTop - pad
            let warmBottom = viewportBottom + pad

            for i in hosts.indices {
                let f = hosts[i].frame
                // Frame is in contentView coords; offset by zoomScale.
                let scale = scrollView.zoomScale
                let scaled = CGRect(
                    x:      f.origin.x * scale,
                    y:      f.origin.y * scale,
                    width:  f.width    * scale,
                    height: f.height   * scale
                )
                let isInBand = scaled.maxY >= warmTop && scaled.minY <= warmBottom
                if isInBand && hosts[i].canvasView == nil {
                    mountCanvas(at: i, in: contentView)
                } else if !isInBand && hosts[i].canvasView != nil && !force {
                    unmountCanvas(at: i)
                }
            }
        }

        private func mountCanvas(at i: Int, in contentView: UIView) {
            guard i < hosts.count else { return }
            guard let page = page(for: hosts[i].pageId) else { return }
            let frame = hosts[i].frame

            let canvas = PKCanvasView(frame: frame)
            canvas.delegate = self
            canvas.backgroundColor = .clear
            canvas.isOpaque = false
            canvas.isScrollEnabled = false
            canvas.maximumZoomScale = 1
            canvas.minimumZoomScale = 1
            canvas.contentInsetAdjustmentBehavior = .never
            canvas.drawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
            // Render stroke colours literally rather than letting PencilKit
            // auto-invert them for "contrast" in dark mode. Without this,
            // a user picking white in a dark-themed app sees their stroke
            // come out as dark grey because PencilKit treats the canvas
            // as dark and flips white → near-black. The page renderer
            // behind the canvas keeps its own trait-aware paper colour.
            canvas.overrideUserInterfaceStyle = .light

            if let data = page.strokeData, let drawing = try? PKDrawing(data: data) {
                canvas.drawing = drawing
            }
            applyTool(viewModel.selectedTool, to: canvas)

            // Pencil double-tap forwarded to the view-model, so the user's
            // configured action (toggle eraser / switch tool / colour
            // picker) fires from any page's canvas.
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = self
            canvas.addInteraction(pencilInteraction)

            contentView.addSubview(canvas)
            hosts[i].canvasView = canvas

            // Keep the overlay layer (audio pins + sticky notes) above
            // every newly-mounted canvas in z-order. Without this,
            // PKCanvasView claims finger hit-tests inside its bounds
            // and the overlays never see taps. Pencil events bypass
            // the overlay via `AudioPassthroughContainer.hitTest`'s
            // stylus check, so this doesn't block drawing.
            if let overlayLayer { contentView.bringSubviewToFront(overlayLayer) }

            // Active-page binding — see updateActivePageFromScroll for the
            // primary ownership of `viewModel.canvasView`.
            if hosts[i].pageId == lastActivePageId {
                viewModel.canvasView = canvas
            }
        }

        private func unmountCanvas(at i: Int) {
            guard i < hosts.count, let canvas = hosts[i].canvasView else { return }
            // Synchronous flush — abandoning a dirty canvas without saving
            // would silently lose strokes when the user scrolls back to the
            // page later.
            if hosts[i].isDirty, let page = page(for: hosts[i].pageId) {
                viewModel.savePage(page, drawing: canvas.drawing)
                hosts[i].isDirty = false
            }
            hosts[i].saveTask?.cancel()
            hosts[i].saveTask = nil
            canvas.removeFromSuperview()
            hosts[i].canvasView = nil
            if viewModel.canvasView === canvas {
                viewModel.canvasView = nil
            }
        }

        // MARK: Active page tracking

        func updateActivePageFromScroll(force: Bool = false) {
            guard let scrollView else { return }
            guard !suppressActivePageUpdates else { return }

            let viewportCentreY = scrollView.contentOffset.y + scrollView.bounds.height / 2
            let scale           = scrollView.zoomScale

            var bestIdx: Int = 0
            var bestDist: CGFloat = .greatestFiniteMagnitude
            for (i, h) in hosts.enumerated() {
                let centreY = (h.frame.midY) * scale
                let dist = abs(centreY - viewportCentreY)
                if dist < bestDist {
                    bestDist = dist
                    bestIdx  = i
                }
            }
            guard bestIdx < hosts.count else { return }
            let activeId = hosts[bestIdx].pageId
            if force || activeId != lastActivePageId {
                lastActivePageId = activeId
                if viewModel.currentPageIndex != bestIdx {
                    viewModel.currentPageIndex = bestIdx
                }
                if let canvas = hosts[bestIdx].canvasView {
                    viewModel.canvasView = canvas
                }
                installOverlayLayerIntoActivePage(animated: !force)
            }
        }

        // MARK: Overlay layer (Phase 1)

        /// Snap the floating overlay layer to the active page's frame so
        /// existing text-block / media / audio overlays render at that
        /// page's coordinates. They read `viewModel.currentPage` and
        /// re-bind on currentPageIndex change, which we update first.
        ///
        /// Phase 2 will replace this with per-page overlays mounted
        /// directly inside each PageHostState.
        func installOverlayLayerIntoActivePage(animated: Bool) {
            guard let overlayLayer else { return }
            guard let host = hosts.first(where: { $0.pageId == lastActivePageId }) else {
                overlayLayer.frame = .zero
                return
            }
            if animated && !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.18) { overlayLayer.frame = host.frame }
            } else {
                overlayLayer.frame = host.frame
            }
        }

        // MARK: Auto-extend last page
        //
        // Stroke-driven: when the user finishes a stroke on the *last*
        // page whose geometry reaches into the bottom half of that page,
        // the last page's height grows by another base-page-height worth
        // of paper. The user keeps writing into the same page; pages
        // only ever pile up if the user explicitly inserts new ones via
        // the page-strip menu. Plain scrolling never grows the page.

        /// Called from `canvasViewDidEndUsingTool` after each stroke
        /// commits. Returns immediately if the stroke isn't on the last
        /// page or doesn't reach the lower half. Throttled to once per
        /// `autoAddCooldown` second so a fast pen with a series of
        /// strokes doesn't extend the page by a mile at once.
        private func considerAutoAddAfterStroke(on canvas: PKCanvasView) {
            guard viewModel.autoAddEnabled else { return }
            guard let lastHost = hosts.last else { return }
            // Must be the last page's canvas.
            guard lastHost.canvasView === canvas else { return }
            guard let lastStroke = canvas.drawing.strokes.last else { return }
            let strokeMaxY = lastStroke.renderBounds.maxY
            let pageMidY   = lastHost.frame.height / 2
            guard strokeMaxY > pageMidY else { return }

            let now = Date()
            guard now.timeIntervalSince(lastAutoAddDate) > autoAddCooldown else { return }
            lastAutoAddDate = now

            guard let lastPage = page(for: lastHost.pageId) else { return }
            // Grow by one base-page-height worth of paper. Roomy enough
            // that the user has plenty to write into; the next extend
            // can fire when this fresh space starts filling up too.
            let increment = lastPage.pageSize.pointSize.height
            viewModel.extendLastPage(lastPage, byAdditional: increment)
        }

        // MARK: Tool / drawing-policy propagation

        func applyToolToAll(_ tool: InkTool) {
            if appliedTool == tool { return }
            appliedTool = tool
            for h in hosts {
                if let canvas = h.canvasView { applyTool(tool, to: canvas) }
            }
        }

        func applyDrawingPolicyToAll(fingerDraws: Bool) {
            let desired: PKCanvasViewDrawingPolicy = fingerDraws ? .anyInput : .pencilOnly
            for h in hosts {
                guard let canvas = h.canvasView else { continue }
                if canvas.drawingPolicy != desired { canvas.drawingPolicy = desired }
            }
        }

        private func applyTool(_ tool: InkTool, to canvasView: PKCanvasView) {
            switch tool {
            case .ruler:
                canvasView.isRulerActive = true
            default:
                canvasView.isRulerActive = false
                canvasView.tool = tool.makePKTool()
            }
        }

        // MARK: Helpers

        private func page(for id: UUID) -> Page? {
            viewModel.pages.first { $0.id == id }
        }

        func scrollToPage(_ index: Int, animated: Bool) {
            guard let scrollView else { return }
            guard index >= 0 && index < hosts.count else { return }
            let host = hosts[index]
            // Centre the page vertically in the viewport.
            let scale = scrollView.zoomScale
            let centreY = host.frame.midY * scale
            let targetY = centreY - scrollView.bounds.height / 2

            // If we're already at (or essentially at) the target, no
            // animation will fire — `scrollViewDidEndScrollingAnimation`
            // never runs, so we'd leave `suppressActivePageUpdates` stuck
            // and the active-page detector wedged. Update synchronously
            // and bail.
            let alreadyThere = abs(scrollView.contentOffset.y - targetY) < 1
            if alreadyThere {
                lastActivePageId = host.pageId
                viewModel.currentPageIndex = index
                if let canvas = host.canvasView { viewModel.canvasView = canvas }
                installOverlayLayerIntoActivePage(animated: false)
                return
            }

            suppressActivePageUpdates = animated
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: animated
            )
            if !animated {
                lastActivePageId = host.pageId
                viewModel.currentPageIndex = index
                if let canvas = host.canvasView { viewModel.canvasView = canvas }
                installOverlayLayerIntoActivePage(animated: false)
            }
        }

        // MARK: Save flush

        func installFlushHandler() {
            viewModel.canvasFlushAllHandler = { [weak self] in
                self?.flushAllDirty()
            }
        }

        func flushAllDirty() {
            for i in hosts.indices {
                guard hosts[i].isDirty,
                      let canvas = hosts[i].canvasView,
                      let page   = page(for: hosts[i].pageId) else { continue }
                viewModel.savePage(page, drawing: canvas.drawing)
                hosts[i].isDirty = false
                hosts[i].saveTask?.cancel()
                hosts[i].saveTask = nil
            }
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if !suppressZoomUpdate {
                let z = scrollView.zoomScale
                if abs(viewModel.zoomScale - z) > 0.001 {
                    viewModel.zoomScale = z
                }
            }
            updateCanvasMembership()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            NotificationCenter.default.post(
                name: .inkCanvasViewportDidChange,
                object: nil,
                userInfo: [
                    "offset": scrollView.contentOffset,
                    "zoom":   scrollView.zoomScale,
                ]
            )
            updateCanvasMembership()
            updateActivePageFromScroll()
            // Auto-add is no longer scroll-driven — it fires on
            // stroke-end via `considerAutoAddAfterStroke(on:)`. Pure
            // scrolling should never grow the notebook.
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            suppressActivePageUpdates = false
            updateActivePageFromScroll(force: true)
            updateCanvasMembership()
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard let i = hosts.firstIndex(where: { $0.canvasView === canvasView }) else { return }
            let pageId = hosts[i].pageId
            hosts[i].isDirty = true
            hosts[i].saveTask?.cancel()
            hosts[i].saveTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled, let self else { return }
                await MainActor.run {
                    guard let idx = self.hosts.firstIndex(where: { $0.pageId == pageId }),
                          let canvas = self.hosts[idx].canvasView,
                          let page   = self.page(for: pageId)
                    else { return }
                    self.viewModel.savePage(page, drawing: canvas.drawing)
                    self.hosts[idx].isDirty = false
                }
            }
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isStrokeInProgress = true
            // Notify the redesigned header's state machine so it can
            // slide out of the way as soon as drawing begins (or, if
            // it was manually revealed, arm the 2-second grace re-hide).
            viewModel.notifyHeaderStrokeBegan()
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isStrokeInProgress = false
            // Hand off to the existing shape-recognition pipeline. It reads
            // viewModel.canvasView, so make sure that points at the canvas
            // the user just drew on.
            viewModel.canvasView = canvasView
            viewModel.handleStrokeEnded()
            // Stroke-end is the only place we consider auto-adding a page.
            considerAutoAddAfterStroke(on: canvasView)
        }

        // MARK: - UIPencilInteractionDelegate

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            viewModel.handlePencilDoubleTap()
        }

        // MARK: - Gestures

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            // Toggle between fit-to-width and 1.0 — same convention as
            // CanvasContainerView.
            let target: CGFloat
            if abs(scrollView.zoomScale - 1.0) > 0.05 {
                target = 1.0
            } else if let widest = hosts.map({ $0.frame.width }).max(), widest > 0 {
                target = scrollView.bounds.width / widest
            } else {
                target = 1.0
            }
            scrollView.setZoomScale(min(scrollView.maximumZoomScale, max(scrollView.minimumZoomScale, target)),
                                     animated: true)
        }

        @objc func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            scrollView.setZoomScale(1.0, animated: true)
        }
    }
}

// MARK: - EditorViewModel additions used by ContinuousCanvasView

extension EditorViewModel {

    /// Append a fresh page at the END of the notebook. Reserved for
    /// explicit user action (page-strip "Insert Page Below" on the last
    /// page, etc.). Auto-add no longer calls this — auto-extend on the
    /// last page is the default behaviour.
    func appendPageForContinuousScroll() {
        guard let last = pages.last else { return }
        guard let _ = try? StorageService.shared.createPage(
            in: notebook,
            after: last.pageNumber,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        ) else { return }
        refreshPages()
        HapticManager.shared.pageAdded()
    }

    /// Grow the last page's vertical extension. Caller passes the
    /// *additional* points of paper to grant (typically one base-page
    /// height); the value accumulates in `PageExtraHeightStore` keyed
    /// by the page's UUID. Bumping `objectWillChange` triggers
    /// SwiftUI to re-render `ContinuousCanvasView`, which detects the
    /// height change in `applyPageMetadataChanges()` and relayouts.
    func extendLastPage(_ page: Page, byAdditional additional: CGFloat) {
        guard additional > 0 else { return }
        PageExtraHeightStore.extend(pageId: page.id, byAdditional: additional)
        page.updatedAt = Date()
        objectWillChange.send()
        refreshPages()
        HapticManager.shared.pageAdded()
    }
}

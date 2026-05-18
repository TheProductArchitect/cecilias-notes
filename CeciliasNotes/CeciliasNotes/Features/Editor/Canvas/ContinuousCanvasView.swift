import Combine
import PencilKit
import SwiftUI
import UIKit

// MARK: - UIHostingController parenting helper
//
// SwiftUI's `UIViewRepresentable` is itself wrapped in a private
// `UIHostingController`. Adding *another* hosting controller's `.view`
// as a raw subview inside that tree triggers the runtime warning
//   "Adding '_UIReparentingView' as a subview of UIHostingController.view
//    is not supported"
// which in turn destabilises the system input infrastructure
// (handwritingd daemon invalidations → SFSpeechRecognizer dies →
// transcription returns empty strings). The fix is to register each
// overlay's hosting controller as a proper child view controller of
// the nearest ancestor UIViewController instead of dangling its view.
private extension UIHostingController {
    /// Walks `parentView`'s responder chain to find the nearest
    /// UIViewController and parents `self` as its child. Retries on the
    /// next runloop tick if no VC is reachable yet (the view may not
    /// be in a window during `makeUIView`).
    func attachAsChild(of parentView: UIView, retriesLeft: Int = 8) {
        var responder: UIResponder? = parentView.next
        while let r = responder {
            if let vc = r as? UIViewController, vc !== self {
                if parent !== vc {
                    if parent != nil {
                        willMove(toParent: nil)
                        removeFromParent()
                    }
                    vc.addChild(self)
                    didMove(toParent: vc)
                }
                return
            }
            responder = r.next
        }
        guard retriesLeft > 0 else { return }
        DispatchQueue.main.async { [weak self, weak parentView] in
            guard let self, let parentView else { return }
            self.attachAsChild(of: parentView, retriesLeft: retriesLeft - 1)
        }
    }

    /// Reverses `attachAsChild` and removes the hosted view from its
    /// superview. Safe to call regardless of attachment state.
    func detachFromParentVC() {
        willMove(toParent: nil)
        view.removeFromSuperview()
        removeFromParent()
    }
}

/// Plain `UIView` subclass whose only job is to fire `onLayoutSubviews`
/// after every layout pass. `ContinuousCanvasView` uses it as the
/// outer host so it can recompute the scroll view's content inset
/// whenever the window/device resizes — the canvas's content inset
/// has to stay equal to `(bounds.width - pageWidth) / 2` to keep the
/// page horizontally centred, but SwiftUI doesn't natively notify a
/// `UIViewRepresentable` on layout-only changes.
private final class CanvasHostView: UIView {
    var onLayoutSubviews: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayoutSubviews?()
    }
}

/// Vertical-stack writing surface.
///
/// Lays every page out vertically inside one `UIScrollView` with
/// `CeciliasNotes.Spacing.lg` gaps (~24pt) of editor background between pages.
/// Pinch-zoom zooms the stack together so all pages scale as one
/// document. Each page is its fixed `page.pageSize.pointSize` — the
/// previous auto-extend-last-page / scroll-mode machinery was
/// removed in Phase 3b. Pages only
/// grow in count when the user explicitly inserts one via the page-strip
/// menu or the `+` page button.
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
struct ContinuousCanvasView: UIViewRepresentable {

    @ObservedObject var viewModel: EditorViewModel
    @AppStorage("ink.canvas.fingerDrawingEnabled") private var fingerDrawingEnabled: Bool = false
    @Environment(\.theme) private var theme

    private let pageGap: CGFloat              = 24
    private let warmBandPaddingFactor: CGFloat = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel,
                    fingerDrawingEnabled: fingerDrawingEnabled,
                    pageGap: pageGap,
                    warmBandPaddingFactor: warmBandPaddingFactor)
    }

    // MARK: makeUIView

    func makeUIView(context: Context) -> UIView {
        let host = CanvasHostView()
        host.backgroundColor = UIColor(theme.pageBackground)
        host.isUserInteractionEnabled = true
        // Re-centre the page horizontally whenever the host's bounds
        // change. `rebuildPageHosts` only fires once in a deferred
        // `DispatchQueue.main.async` from this method, by which point
        // the scroll view's bounds may not yet equal the final
        // window width. With `bounds.width == 0` at that moment the
        // computed `hInset` is `0` on both sides and the page hugs
        // the left edge (visible as the "narrow column on the left,
        // massive whitespace on the right" symptom). Refiring on
        // every layout pass keeps the content inset in sync.
        host.onLayoutSubviews = { [weak coord = context.coordinator] in
            coord?.refreshContentInsetForBounds()
        }

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

        // Sticky notes — per-page mount, see `rebuildPageHosts`. The
        // legacy global single overlay was removed in Phase 3b.

        // Text block overlay — same floating-active-page model as
        // Text-block overlay — per-page mount, see `rebuildPageHosts`.
        // The legacy global single overlay was removed in Phase 3b.

        context.coordinator.host             = host
        context.coordinator.scrollView       = scrollView
        context.coordinator.contentView      = contentView
        context.coordinator.overlayLayer     = overlayLayer
        // `audioPinsHost` is intentionally left nil — audio pin
        // overlays now mount per-page inside each `PageRenderer`
        // (see the page-mount loop below). The coordinator's
        // `audioPinsHost` slot stays in the model for legacy
        // diagnostics but isn't populated.

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
        // Non-drawing tools (text / image / sticky-note) need finger
        // taps to reach the SwiftUI overlays underneath the canvas.
        // PKCanvasView's gesture recognisers swallow taps even in
        // `.pencilOnly` mode, so we have to disable user interaction
        // on every mounted canvas while a non-drawing tool is active.
        // Phase 5E: consult the single-source `canvasIsInteractive`
        // signal instead of reading `selectedTool.isDrawingTool`
        // directly. The state machine adds the mode-axis check so a
        // lecture / audio recording also suppresses Pencil input
        // even when a drawing tool is selected.
        coord.applyOverlayHitTestingToAll(canvasInteractive: viewModel.canvasIsInteractive)
        // Bring the active-tool's overlay to the front inside each
        // renderer so finger taps on images / sticky-notes / text
        // blocks aren't swallowed by another overlay's hosting view.
        // See Bug 4.
        coord.promoteActiveOverlayToFront(for: viewModel.selectedTool)

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

        weak var host:         UIView?
        weak var scrollView:   UIScrollView?
        weak var contentView:  UIView?
        weak var overlayLayer: UIView?
        // Strong ref — UIHostingController keeps the SwiftUI overlay
        // alive. Released when the coordinator deinits (i.e. when the
        // editor view is dismissed).
        var audioPinsHost: UIHostingController<AudioAnnotationCardsOverlayView>?

        struct PageHostState {
            let pageId: UUID
            var frame: CGRect              // in contentView coords
            let renderer: PageRenderer     // always mounted (paper bg)
            /// SwiftUI `TemplatePatternView` mounted inside the
            /// renderer to paint the page's template pattern. Kept as
            /// a strong ref alongside the renderer so the controller
            /// outlives `mountCanvas` / `unmountCanvas` cycles.
            var templateHost: UIHostingController<TemplatePatternView>
            /// Image attachments overlay (BELOW the canvas). Stored so
            /// the hosting controller outlives the page's lifetime — a
            /// dangling HC stops driving SwiftUI updates and also
            /// triggers `_UIReparentingView` complaints.
            var imagesHost:    UIHostingController<ImageAttachmentsView>
            /// Audio annotation pins overlay (ABOVE the canvas).
            var audioPinsHost: UIHostingController<AudioAnnotationCardsOverlayView>
            /// Lecture-block overlay (ABOVE the canvas).
            var lectureHost:   UIHostingController<LectureBlocksOverlayView>
            /// Sticky-notes overlay (ABOVE the canvas). Phase 3b: was a
            /// single global overlay in `overlayLayer`, now per-page.
            var stickyHost:    UIHostingController<StickyNotesOverlayView>
            /// Text-block overlay (ABOVE the canvas). Phase 3b: was a
            /// single global overlay in `overlayLayer`, now per-page.
            var textBlockHost: UIHostingController<TextBlockOverlayView>
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
        private var isStrokeInProgress = false
        var appliedTool: CeciliasNotesTool?
        /// Throttle for auto-add-page-on-bottom-stroke. Without this a
        /// flurry of short strokes near the bottom of the last page would
        /// spawn multiple pages back-to-back.
        private var lastAutoAddDate: Date = .distantPast

        init(viewModel: EditorViewModel,
             fingerDrawingEnabled: Bool,
             pageGap: CGFloat,
             warmBandPaddingFactor: CGFloat) {
            self.viewModel = viewModel
            self.fingerDrawingEnabled = fingerDrawingEnabled
            self.pageGap = pageGap
            self.warmBandPaddingFactor = warmBandPaddingFactor
        }

        deinit {
            // Detach the sticky-notes hosting controller from its
            // parent VC so it doesn't outlive the editor screen as a
            // dangling child VC. Per-page hosting controllers are
            // detached inside `tearDownAllHosts`; this covers the one
            // installed in `makeUIView` that isn't part of the page
            // loop. Capturing as a local prevents the `MainActor`-only
            // call from running off-actor in a deinit chain.
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
                let frame = CGRect(
                    x: (maxW - baseSize.width) / 2,
                    y: y,
                    width: baseSize.width,
                    height: baseSize.height
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
                templateHost.attachAsChild(of: renderer)

                // Image attachments layer — sits ABOVE the
                // background (template / PDF) and BELOW the
                // PencilKit canvas. The hierarchy is non-negotiable
                // per the architecture rule: PKCanvasView is always
                // the topmost interactive layer so handwriting
                // overwrites images cleanly.
                //
                // Pass the *base* page size (not the effective
                // height `h` which includes auto-extension extra
                // space). The image overlay normalises positions
                // against this size, so when the page auto-extends
                // after a stroke near the bottom, images stay
                // anchored to their original absolute coordinates
                // instead of shifting down proportionally with the
                // grown height. Images live in the original page
                // rect; the extended region is canvas-only.
                // Single placement primitive shared by every per-page
                // overlay below — base size only, no effective height.
                // See `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.A.
                let pageCS = PageCoordinateSpace(baseSize: baseSize)

                let imagesHost = UIHostingController(
                    rootView: ImageAttachmentsView(
                        viewModel: viewModel,
                        pageId: page.id,
                        coordinateSpace: pageCS
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
                imagesHost.attachAsChild(of: renderer)

                // Audio annotation overlay — per-page, scoped to
                // this page's id. Phase 4B: replaced the pin overlay
                // with full-width cards stacked from the top of the
                // page. Cards are always interactive (tap to expand
                // transcript, long-press for context menu) regardless
                // of the selected tool.
                let audioPinsHost = UIHostingController(
                    rootView: AudioAnnotationCardsOverlayView(
                        viewModel: viewModel,
                        pageId: page.id,
                        coordinateSpace: pageCS
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
                audioPinsHost.attachAsChild(of: renderer)

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
                        coordinateSpace: pageCS
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
                lectureHost.attachAsChild(of: renderer)

                // Sticky-notes overlay — per-page mount (Phase 3b).
                let stickyHost = UIHostingController(
                    rootView: StickyNotesOverlayView(
                        viewModel: viewModel,
                        pageId: page.id,
                        coordinateSpace: pageCS
                    )
                )
                stickyHost.view.backgroundColor = .clear
                stickyHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(stickyHost.view)
                NSLayoutConstraint.activate([
                    stickyHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    stickyHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    stickyHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    stickyHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])
                stickyHost.attachAsChild(of: renderer)

                // Text-block overlay — per-page mount (Phase 3b). Same
                // overlay also handles `lecture:<uuid>`-prefixed blocks
                // by routing them through `LectureBlockView` internally.
                let textBlockHost = UIHostingController(
                    rootView: TextBlockOverlayView(
                        viewModel: viewModel,
                        pageId: page.id,
                        coordinateSpace: pageCS
                    )
                )
                textBlockHost.view.backgroundColor = .clear
                textBlockHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(textBlockHost.view)
                NSLayoutConstraint.activate([
                    textBlockHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    textBlockHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    textBlockHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    textBlockHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])
                textBlockHost.attachAsChild(of: renderer)

                contentView.addSubview(renderer)
                hosts.append(PageHostState(
                    pageId:        page.id,
                    frame:         frame,
                    renderer:      renderer,
                    templateHost:  templateHost,
                    imagesHost:    imagesHost,
                    audioPinsHost: audioPinsHost,
                    lectureHost:   lectureHost,
                    stickyHost:    stickyHost,
                    textBlockHost: textBlockHost,
                    template:      page.backgroundTemplate
                ))
                y += baseSize.height + pageGap
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
                // Detach the four overlay hosting controllers from
                // their parent view controller before the renderer is
                // removed — otherwise the VC graph holds dangling
                // children whose `.view` no longer has a window.
                hosts[i].templateHost.detachFromParentVC()
                hosts[i].imagesHost.detachFromParentVC()
                hosts[i].audioPinsHost.detachFromParentVC()
                hosts[i].lectureHost.detachFromParentVC()
                hosts[i].stickyHost.detachFromParentVC()
                hosts[i].textBlockHost.detachFromParentVC()
                hosts[i].renderer.removeFromSuperview()
            }
            hosts.removeAll()
        }

        /// Refresh `PageRenderer.template` / `PageRenderer.pageSize`
        /// when a page's metadata changed without the page list itself
        /// changing. Customise panel mutations land here. A change to
        /// `pageSize` reshapes the layout, so we trigger a full rebuild
        /// of host frames + content size in that case.
        private func applyPageMetadataChanges() {
            var needsLayoutRebuild = false
            for i in hosts.indices {
                guard let page = page(for: hosts[i].pageId) else { continue }
                let templateChanged = hosts[i].template != page.backgroundTemplate
                let pageSizeChanged = hosts[i].renderer.pageSize != page.pageSize
                if pageSizeChanged {
                    hosts[i].renderer.update(pageSize: page.pageSize)
                }
                if templateChanged {
                    hosts[i].template = page.backgroundTemplate
                    hosts[i].templateHost.rootView =
                        TemplatePatternView(template: page.backgroundTemplate)
                }
                if pageSizeChanged {
                    needsLayoutRebuild = true
                }
            }
            if needsLayoutRebuild {
                relayoutHosts()
            }
        }

        /// Recompute every host's frame in place (without tearing down
        /// canvases), then update the scroll view's content size. Used
        /// when the user changes a page's size via the Customise panel.
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
                let baseSize = page.pageSize.pointSize
                let frame = CGRect(
                    x: (maxW - baseSize.width) / 2,
                    y: y,
                    width: baseSize.width,
                    height: baseSize.height
                )
                hosts[i].frame = frame
                hosts[i].renderer.frame = frame
                hosts[i].canvasView?.frame = frame
                y += baseSize.height + pageGap
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
            applyContentInset()
        }

        /// Recompute the scroll view's content inset against its
        /// current bounds + content size. Called from
        /// `updateContentSize` (when the page list changes) AND from
        /// the host's `layoutSubviews` hook (when the window
        /// resizes / orientation flips / the editor cover first
        /// becomes visible at a non-zero bounds). The horizontal
        /// inset is what keeps the page visually centred — without
        /// re-firing on bounds change, an early layout pass with
        /// `bounds.width == 0` locks the inset at zero and the page
        /// stays pinned to the scroll view's left edge.
        func refreshContentInsetForBounds() {
            applyContentInset()
        }

        private func applyContentInset() {
            guard let scrollView else { return }
            let width  = scrollView.contentSize.width
            let height = scrollView.contentSize.height
            // Skip when bounds aren't yet sized — the host's
            // `layoutSubviews` will re-fire once SwiftUI gives the
            // representable its real frame.
            guard scrollView.bounds.width > 0, width > 0 else { return }
            let hInset = max(0, (scrollView.bounds.width  - width)  / 2)
            let vInset = max(0, scrollView.bounds.height / 2 - height / 2)
            let newInset = UIEdgeInsets(
                top:    Swift.max(scrollView.bounds.height * 0.10, vInset),
                left:   hInset,
                bottom: Swift.max(scrollView.bounds.height * 0.10, vInset),
                right:  hInset
            )
            // Only assign when actually different — setting the
            // inset always triggers a `setContentOffset` adjustment
            // that can fight the user's in-flight scroll.
            if scrollView.contentInset != newInset {
                scrollView.contentInset = newInset
            }
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

            // `CeciliasNotesPKCanvasView` overrides `addGestureRecognizer` to
            // reject `UIHoverGestureRecognizer` at install time —
            // prevents the iPadOS 17.5+ Pencil-hover layout pass that
            // shifted rendered strokes. See
            // `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.D.
            let canvas = CeciliasNotesPKCanvasView(frame: frame)
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
            // Honour current text-mode state at mount time. Without
            // this a canvas mounted while the user is already in
            // text mode would intercept finger taps for the first
            // tool-change cycle.
            // Disable canvas hit-testing for any non-drawing tool (text /
            // image / sticky-note). PKCanvasView's gesture recognisers
            // greedily consume finger taps even in `.pencilOnly` mode,
            // which prevents the SwiftUI overlays underneath
            // (ImageAttachmentsView, TextBlockOverlayView,
            // StickyNotesOverlayView) from ever seeing taps. Tying this to
            // `isDrawingTool` keeps Pencil drawing disabled in those modes
            // (acceptable — the user explicitly switched away from a
            // drawing tool) while letting finger taps reach the overlays.
            // Phase 5E: single-source `canvasIsInteractive` (tool +
            // mode axis combined) — see `EditorStateMachine`.
            canvas.isUserInteractionEnabled = viewModel.canvasIsInteractive

            // Pencil double-tap forwarded to the view-model, so the user's
            // configured action (toggle eraser / switch tool / colour
            // picker) fires from any page's canvas.
            let pencilInteraction = UIPencilInteraction()
            pencilInteraction.delegate = self
            canvas.addInteraction(pencilInteraction)
            #if DEBUG
            print("[Pencil-diag] mountCanvas registered UIPencilInteraction interaction=\(ObjectIdentifier(pencilInteraction).hashValue) on canvas page=\(hosts[i].pageId)")
            #endif

            // Hover-recogniser rejection happens inside
            // `CeciliasNotesPKCanvasView.addGestureRecognizer`. No post-hoc walk
            // is required — see the subclass's header comment.

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

        // MARK: Tool / drawing-policy propagation

        func applyToolToAll(_ tool: CeciliasNotesTool) {
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

        /// Toggle `isUserInteractionEnabled` on every mounted canvas
        /// based on whether the selected tool is a drawing tool.
        /// PencilKit's `drawingPolicy` only controls *drawing* input —
        /// its own gesture recognisers still consume finger taps even
        /// in pencilOnly mode, which prevents the SwiftUI overlays
        /// (text / image / sticky-note) from receiving taps. Disabling
        /// user interaction on the canvas is the only reliable way to
        /// let taps fall through.
        ///
        /// The trade-off: Pencil drawing is also blocked while a
        /// non-drawing tool is active. Acceptable — the user
        /// explicitly switched away from a drawing tool. Switching
        /// back to any drawing tool restores `true`.
        func applyOverlayHitTestingToAll(canvasInteractive desired: Bool) {
            for h in hosts {
                guard let canvas = h.canvasView else { continue }
                if canvas.isUserInteractionEnabled != desired {
                    canvas.isUserInteractionEnabled = desired
                }
                #if DEBUG
                print("[ImageInteract] canvas isUserInteractionEnabled=\(canvas.isUserInteractionEnabled), tool=\(viewModel.selectedTool)")
                #endif
            }
        }

        /// Bring the per-page overlay matching the active tool to the
        /// front inside its renderer. Without this, the per-page overlay
        /// stack order (image → audio → lecture → sticky → text) means
        /// the text-block hosting view sits on TOP of the image overlay,
        /// and `UIHostingController.view` absorbs finger hits even when
        /// its SwiftUI body has no interactive content. Re-ordering the
        /// SwiftUI hosting views per the active tool puts the right
        /// overlay's tap-catcher first in the responder chain. See Bug 4.
        func promoteActiveOverlayToFront(for tool: CeciliasNotesTool) {
            for h in hosts {
                let renderer = h.renderer
                switch true {
                case tool.isImageMode:
                    renderer.bringSubviewToFront(h.imagesHost.view)
                case tool.isStickyNoteMode:
                    renderer.bringSubviewToFront(h.stickyHost.view)
                case tool.isTextMode:
                    renderer.bringSubviewToFront(h.textBlockHost.view)
                default:
                    // Drawing tools — restore the original stacking
                    // order (text on top, then sticky, lecture, audio,
                    // images, template). Image / sticky / text all need
                    // to render under the canvas anyway when a drawing
                    // tool is active.
                    renderer.bringSubviewToFront(h.textBlockHost.view)
                    renderer.bringSubviewToFront(h.stickyHost.view)
                    renderer.bringSubviewToFront(h.lectureHost.view)
                    renderer.bringSubviewToFront(h.audioPinsHost.view)
                }
            }
        }

        private func applyTool(_ tool: CeciliasNotesTool, to canvasView: PKCanvasView) {
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
                name: .ceciliasNotesCanvasViewportDidChange,
                object: nil,
                userInfo: [
                    "offset": scrollView.contentOffset,
                    "zoom":   scrollView.zoomScale,
                ]
            )
            updateCanvasMembership()
            updateActivePageFromScroll()
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
            considerAutoAddAfterStroke(on: canvasView)
        }

        /// If the just-finished stroke lands in the bottom 15% of the *last*
        /// page's canvas and auto-add is on, append a new page after it and
        /// scroll to reveal it. Throttled to one fire per second so a flurry
        /// of small strokes near the bottom doesn't spawn multiple pages.
        private func considerAutoAddAfterStroke(on canvasView: PKCanvasView) {
            guard viewModel.autoAddEnabled else { return }
            guard let host = hosts.first(where: { $0.canvasView === canvasView }) else { return }
            guard let lastPageId = viewModel.pages.last?.id, host.pageId == lastPageId else { return }
            guard let stroke = canvasView.drawing.strokes.last else { return }
            let canvasHeight = canvasView.bounds.height
            guard canvasHeight > 0 else { return }
            let threshold = canvasHeight * 0.85
            guard stroke.renderBounds.maxY >= threshold else { return }
            let now = Date()
            guard now.timeIntervalSince(lastAutoAddDate) > 1.0 else { return }
            lastAutoAddDate = now
            // Defer the mutation to the next runloop tick — mutating
            // `@Published` state from a PencilKit delegate callback is the
            // exact pattern that triggers AttributeGraph cycle warnings.
            let pageId = host.pageId
            Task { @MainActor [weak viewModel] in
                viewModel?.addPage(afterPageId: pageId)
            }
        }

        // MARK: - UIPencilInteractionDelegate

        // Pencil 2 (iPad Pro / iPad Air with original Apple Pencil 2):
        // the system calls this legacy method on double-tap.
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            #if DEBUG
            print("[Pencil] double-tap fired (legacy API) action=\(viewModel.activePencilDoubleTapAction.rawValue)")
            print("[Pencil-diag] tap handler entered interaction=\(ObjectIdentifier(interaction).hashValue) thread=\(Thread.current.description)")
            Thread.callStackSymbols.prefix(8).forEach { print("[Pencil-diag]   \($0)") }
            #endif
            viewModel.handlePencilDoubleTap()
        }

        // Apple Pencil Pro (iPad Pro M4, iPad Air M2/M3): the system
        // calls this iOS 17.5+ method instead. Without this method, a
        // Pencil Pro double-tap silently doesn't fire — the legacy
        // `pencilInteractionDidTap(_:)` is only consulted for older
        // Pencil hardware. Both delegate methods must be implemented
        // so the editor works across the full Pencil matrix. See Bug 5.
        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveTap tap: UIPencilInteraction.Tap
        ) {
            // `UIPencilInteraction.Tap` is a discrete event (no
            // `phase` member). One delegate call = one user-perceived
            // double-tap — fire the action once and exit.
            #if DEBUG
            print("[Pencil] double-tap fired (Pencil Pro API) action=\(viewModel.activePencilDoubleTapAction.rawValue)")
            print("[Pencil-diag] tap handler entered interaction=\(ObjectIdentifier(interaction).hashValue) thread=\(Thread.current.description)")
            Thread.callStackSymbols.prefix(8).forEach { print("[Pencil-diag]   \($0)") }
            #endif
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

}

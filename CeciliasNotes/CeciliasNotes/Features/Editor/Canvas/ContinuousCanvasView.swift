import Combine
import PencilKit
import SwiftData
import SwiftUI
import UIKit

// MARK: - Palm-rejecting scroll view

/// `UIScrollView` subclass that drops palm contacts from its built-in
/// pinch-zoom recognizer. A resting palm registers as large-radius
/// `.direct` touches; without this, the moment the hand lands the
/// pinch recognizer reads two of them as a zoom (the "accidental
/// zoom on palm plant" bug).
///
/// This MUST be done by subclassing — `UIScrollView` requires that its
/// built-in pinch recognizer keep the scroll view itself as delegate
/// (reassigning it throws `NSInvalidArgumentException`). The scroll
/// view *is* its own gesture delegate, so overriding the delegate
/// method here is the supported hook. We return `true` for every
/// non-palm / non-pinch case, matching UIKit's default, and only veto
/// palm-sized touches reaching the pinch recognizer — pan, fingertip
/// pinches, and Pencil input are untouched.
final class PalmRejectingScrollView: UIScrollView {
    /// `majorRadius` cutoff: comfortably above a fingertip (~10–25pt),
    /// well below a resting palm/forearm contact.
    private let palmRadiusThreshold: CGFloat = 60

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldReceive touch: UITouch
    ) -> Bool {
        if gestureRecognizer === pinchGestureRecognizer,
           touch.type == .direct,
           touch.majorRadius > palmRadiusThreshold {
            return false
        }
        return true
    }
}

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
    /// User's resolution policy. Step 3 replaced the binary
    /// `fingerDrawingEnabled` toggle with a three-mode picker
    /// (`.auto` / `.always` / `.never`). The resolved bool used by
    /// PKCanvasView's drawing policy is computed from this mode +
    /// `InputCapabilityDetector.shared.hasPencil` in
    /// `resolvedFingerDrawingEnabled`.
    @AppStorage("ceciliasnotes.canvas.fingerDrawingMode") private var fingerDrawingMode: FingerDrawingMode = .auto
    /// Bumped on `.inputCapabilityChanged` so view-tree updates
    /// re-evaluate the resolved bool after the first pencil touch
    /// flips `hasPencil`. AppStorage already drives updates for
    /// the mode side.
    @State private var capabilityTick: Int = 0
    @Environment(\.theme) private var theme

    /// Resolved finger-drawing bool that the canvas plumbing
    /// expects. Reads the mode + detector each evaluation; cheap.
    private var resolvedFingerDrawingEnabled: Bool {
        let _ = capabilityTick
        return fingerDrawingMode.fingerDrawingEnabled(
            hasPencil: InputCapabilityDetector.shared.hasPencil
        )
    }

    private let pageGap: CGFloat              = 24
    private let warmBandPaddingFactor: CGFloat = 1.0

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel,
                    fingerDrawingEnabled: resolvedFingerDrawingEnabled,
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

        let scrollView = PalmRejectingScrollView(frame: host.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 0.5
        // Capped at 1.5× (+50% from native). Higher values were available
        // but caused stroke-rendering blur and made the active page hard
        // to keep on-screen; pinching to ~2× was nearly always followed
        // by a double-tap back to 1×.
        scrollView.maximumZoomScale = 1.5
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
        // Two-finger pan only when both finger-drawing is on AND a
        // drawing tool is selected. See updateUIView for the same gate.
        let fingersDrawingNow0 = resolvedFingerDrawingEnabled && viewModel.selectedTool.isDrawingTool
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingersDrawingNow0 ? 2 : 1
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
        // Don't steal double-taps that land on a UITextView — that's
        // word-select, not fit-to-width zoom. Same for the two-finger
        // variant so it doesn't clash with text selection either.
        doubleTap.delegate = context.coordinator
        twoFingerDoubleTap.delegate = context.coordinator
        scrollView.addGestureRecognizer(doubleTap)
        // NOTE: a single-tap "global dismiss" recognizer used to be
        // attached here to resign the keyboard on any tap outside a
        // UITextView. Even with `cancelsTouchesInView = false`, the
        // recognizer's mere presence on the scrollview interfered
        // with single-finger pan-to-scroll under some configurations
        // (the "scroll function is not working" report). The
        // per-page background-tap catcher in
        // `TextElementsOverlayView.showsBackgroundCatcher` covers
        // the in-page dismissal case without touching the scroll
        // gesture machinery; if global out-of-page dismissal is
        // needed later we'll do it through a UIKit window-level
        // tap-outside instead.

        // Defer initial layout to the next runloop so SwiftUI's frame
        // assignment has settled.
        DispatchQueue.main.async {
            context.coordinator.rebuildPageHosts()
            context.coordinator.scrollToPage(viewModel.currentPageIndex, animated: false)
            context.coordinator.installOverlayLayerIntoActivePage(animated: false)
            context.coordinator.installFlushHandler()
            #if DEBUG
            // Fix 1 — touch-path diagnostic. Instrument the outer
            // layers (window / editor root / scroll view). Per-page
            // layers are instrumented in `rebuildPageHosts` /
            // `mountCanvas`. Observe-only — see `TouchPathLogger`.
            if let window = host.window {
                TouchPathLogger.attach(to: window, label: "1. UIWindow")
            }
            TouchPathLogger.attach(to: host, label: "2. editor root (CanvasHostView)")
            TouchPathLogger.attach(to: scrollView, label: "3. scroll view")
            #endif
        }
        return host
    }

    // MARK: updateUIView

    func updateUIView(_ host: UIView, context: Context) {
        let coord = context.coordinator
        guard let scrollView = coord.scrollView else { return }

        let fingerDraws = resolvedFingerDrawingEnabled
        coord.fingerDrawingEnabled = fingerDraws

        // Pan gesture touch count: require two fingers only when a
        // drawing tool is active and finger-drawing is on. In cursor
        // mode (or any non-drawing tool) the canvas isn't consuming
        // finger input, so single-finger pan must scroll the document
        // — otherwise the user gets a frozen-looking page.
        let fingersDrawingNow = fingerDraws && viewModel.selectedTool.isDrawingTool
        let desiredTouches = fingersDrawingNow ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != desiredTouches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = desiredTouches
        }

        // Drawing policy + tool propagate to every mounted canvas. Cheap
        // — typically 3–5 canvases live at once.
        coord.applyDrawingPolicyToAll(fingerDraws: fingerDraws)
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
        // OPEN_ISSUES #1: per-tool overlay z-order promotion is gone.
        // With every overlay in one `PageOverlaysContainer`, SwiftUI
        // routes each tap to the element actually at the point — a
        // fixed ZStack order is all that's needed, no per-tool
        // `bringSubviewToFront` shuffling.

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
        // Step 5 retired the V5 `AudioAnnotationCardsOverlayView`
        // global-overlay slot; audio is per-page now via the V6
        // `AudioElementsOverlayView` mounted inside each renderer.
        // The unused slot stays nil — leaving it here so future
        // diagnostic hooks have a place to live without a struct
        // change.
        var audioPinsHost: UIView?

        struct PageHostState {
            let pageId: UUID
            var frame: CGRect              // in contentView coords
            let renderer: PageRenderer     // always mounted (paper bg)
            /// SwiftUI `TemplatePatternView` mounted inside the
            /// renderer to paint the page's template pattern. Kept as
            /// a strong ref alongside the renderer so the controller
            /// outlives `mountCanvas` / `unmountCanvas` cycles.
            var templateHost: UIHostingController<TemplatePatternView>
            /// OPEN_ISSUES #1 — every interactive per-page overlay
            /// (stroke seed, legacy text-block, image, PDF page,
            /// highlight, audio, sticky note, V6 text element,
            /// lasso) is hosted inside ONE `PageOverlaysContainer`
            /// rather than nine separate `UIHostingController`s.
            /// A `_UIHostingView` claims its whole frame for
            /// hit-testing whenever it is interaction-enabled, so
            /// stacked separate hosts meant the topmost absorbed
            /// every tap before the overlays below it were reached.
            /// One host = one SwiftUI tree = correct internal hit
            /// routing. See `PageOverlaysContainer`.
            var overlaysHost: UIHostingController<PageOverlaysContainer>
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

        /// Token for the `.inputCapabilityChanged` observer set up
        /// in `init`. Released in `deinit`. Step 3: re-applies the
        /// canvas drawing policy the moment the first pencil touch
        /// flips `InputCapabilityDetector.hasPencil`, so `.auto`
        /// mode users transitioning from finger-only to pencil
        /// don't have to wait for the next SwiftUI tick to lock the
        /// canvas down to pencilOnly.
        private nonisolated(unsafe) var capabilityObserver: NSObjectProtocol?

        init(viewModel: EditorViewModel,
             fingerDrawingEnabled: Bool,
             pageGap: CGFloat,
             warmBandPaddingFactor: CGFloat) {
            self.viewModel = viewModel
            self.fingerDrawingEnabled = fingerDrawingEnabled
            self.pageGap = pageGap
            self.warmBandPaddingFactor = warmBandPaddingFactor
            super.init()
            self.capabilityObserver = NotificationCenter.default.addObserver(
                forName: .inputCapabilityChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // Re-read the mode from AppStorage at notification
                // time. The resolved bool may flip from anyInput to
                // pencilOnly (or vice versa) when hasPencil changes
                // under `.auto` mode.
                let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.canvas.fingerDrawingMode")
                let mode = raw.flatMap(FingerDrawingMode.init(rawValue:)) ?? .auto
                let fingerDraws = mode.fingerDrawingEnabled(
                    hasPencil: InputCapabilityDetector.shared.hasPencil
                )
                self.fingerDrawingEnabled = fingerDraws
                self.applyDrawingPolicyToAll(fingerDraws: fingerDraws)
            }
        }

        deinit {
            if let token = capabilityObserver {
                NotificationCenter.default.removeObserver(token)
            }
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
            // Fast path: pages appended at the end (the auto-add
            // case). Tearing down every host on a one-page append
            // causes the visible "page refresh" blink that drops any
            // in-flight stroke on the currently-active canvas. We
            // only need to mount the new pages — existing canvases,
            // overlay hosts, and PKDrawings can stay exactly where
            // they are.
            let pages = viewModel.pages
            if isPurelyAppended(old: lastSnapshot, new: snapshot),
               canAppendInPlace(newPages: pages) {
                let appendedStart = lastSnapshot.count
                let appendedPages = Array(pages[appendedStart...])
                appendPageHosts(appendedPages)
                return
            }
            // Phase 1 simplification: rebuild from scratch on any list
            // change. The cost is 1× PKDrawing reload per page in the warm
            // band, which dominates and is independent of the rebuild.
            rebuildPageHosts()
        }

        /// True iff `new` equals `old` followed by zero or more
        /// additional page IDs (the auto-add / "+ new page" case).
        private func isPurelyAppended(old: [UUID], new: [UUID]) -> Bool {
            guard new.count > old.count else { return false }
            for i in 0..<old.count where old[i] != new[i] { return false }
            return true
        }

        /// True iff the appended pages don't widen `maxW` — if they
        /// did, every existing page would need to be re-centred
        /// horizontally, and the full rebuild path is simpler.
        private func canAppendInPlace(newPages: [Page]) -> Bool {
            let currentMaxW = hosts.map(\.frame.width).max() ?? 0
            let newMaxW = newPages.map { $0.pageSize.pointSize.width }.max() ?? 0
            return newMaxW <= currentMaxW + 0.5
        }

        func rebuildPageHosts() {
            guard contentView != nil else { return }
            tearDownAllHosts()
            var y: CGFloat = 0
            // Use the widest page as the content width so a mixed-size
            // notebook (e.g. A4 + Letter) stays centred without horizontal
            // jitter while scrolling.
            let pages   = viewModel.pages
            let maxW    = pages.map { $0.pageSize.pointSize.width }.max() ?? PageSize.a4.pointSize.width
            for page in pages {
                y = mountPageHost(page, atY: y, contentMaxWidth: maxW)
            }
            // Total content height excludes the trailing gap.
            let height = max(0, y - pageGap)
            updateContentSize(width: maxW, height: height)
            lastSnapshot = pages.map(\.id)

            // Mount canvases for the warm band straight away so the user
            // doesn't see a paper-only flash when entering the editor.
            updateCanvasMembership(force: true)
        }

        /// Append `newPages` to the bottom of the existing host
        /// stack without touching any existing host. Used by the
        /// auto-add fast path — keeps the active canvas's PKDrawing
        /// and in-flight stroke intact while one extra page slides
        /// in below.
        private func appendPageHosts(_ newPages: [Page]) {
            guard contentView != nil else { return }
            // y picks up where the last existing host ended.
            var y: CGFloat = (hosts.last?.frame.maxY).map { $0 + pageGap } ?? 0
            let maxW = hosts.map(\.frame.width).max()
                ?? newPages.first?.pageSize.pointSize.width
                ?? PageSize.a4.pointSize.width
            for page in newPages {
                y = mountPageHost(page, atY: y, contentMaxWidth: maxW)
            }
            let height = max(0, y - pageGap)
            updateContentSize(width: maxW, height: height)
            lastSnapshot = viewModel.pages.map(\.id)
            // Non-forced membership refresh so canvases already mounted
            // on existing hosts stay mounted. The new page's canvas
            // will mount if it falls in the warm band; otherwise it
            // sits as paper until the user scrolls into it.
            updateCanvasMembership(force: false)
        }

        /// Mount one page's renderer / template host / overlays host
        /// at `y` and append a `PageHostState`. Returns the new `y`
        /// (advance for the next page). Extracted so the full
        /// rebuild and the append-only path share one canonical
        /// per-page mount.
        @discardableResult
        private func mountPageHost(
            _ page: Page,
            atY y: CGFloat,
            contentMaxWidth maxW: CGFloat
        ) -> CGFloat {
            guard let contentView else { return y }
            let baseSize = page.pageSize.pointSize
            let frame = CGRect(
                x: (maxW - baseSize.width) / 2,
                y: y,
                width: baseSize.width,
                height: baseSize.height
            )
            let renderer = PageRenderer(pageSize: page.pageSize)
            renderer.frame = frame

                // Step 5.5: PageRenderer no longer draws PDFs or
                // highlights — those flow through
                // `PDFPageElementsOverlayView` and
                // `HighlightElementsOverlayView` respectively. The
                // renderer just paints paper + template now.

                // Mount the SwiftUI template pattern inside the
                // renderer so paper colour (UIKit, theme-aware) sits
                // behind the pattern (SwiftUI Canvas, theme-agnostic).
                let templateHost = UIHostingController(
                    rootView: TemplatePatternView(template: page.backgroundTemplate)
                )
                templateHost.view.backgroundColor = .clear
                templateHost.view.isUserInteractionEnabled = false
                templateHost.view.isHidden = false
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

                // OPEN_ISSUES #1 — every interactive overlay (stroke
                // seed, legacy text-block, image, PDF page, highlight,
                // audio, sticky, V6 text element, lasso) is hosted in
                // ONE `PageOverlaysContainer` so a single SwiftUI tree
                // owns hit routing. Stacking nine separate hosts is
                // what caused the gesture absorption: a `_UIHostingView`
                // claims its whole frame whenever it is
                // interaction-enabled, so the topmost host swallowed
                // every tap. See `PageOverlaysContainer`. The template
                // pattern stays a separate host (mounted above) — it's
                // non-interactive and needs its own `rootView` swap
                // when the Customise panel changes the template.
                let overlaysHost = UIHostingController(
                    rootView: PageOverlaysContainer(
                        viewModel: viewModel,
                        pageId: page.id,
                        notebookId: viewModel.notebook.id,
                        coordinateSpace: pageCS
                    )
                )
                overlaysHost.view.backgroundColor = .clear
                overlaysHost.view.translatesAutoresizingMaskIntoConstraints = false
                renderer.addSubview(overlaysHost.view)
                NSLayoutConstraint.activate([
                    overlaysHost.view.topAnchor.constraint(equalTo: renderer.topAnchor),
                    overlaysHost.view.leadingAnchor.constraint(equalTo: renderer.leadingAnchor),
                    overlaysHost.view.trailingAnchor.constraint(equalTo: renderer.trailingAnchor),
                    overlaysHost.view.bottomAnchor.constraint(equalTo: renderer.bottomAnchor),
                ])
                overlaysHost.attachAsChild(of: renderer)

                contentView.addSubview(renderer)

                #if DEBUG
                // OPEN_ISSUES #1 touch-path diagnostic. Only two
                // renderer subviews carry interaction now: the
                // renderer itself and the single overlays host.
                let pidTag = page.id.uuidString.prefix(8)
                TouchPathLogger.attach(to: renderer,
                                       label: "4. page \(pidTag) renderer")
                TouchPathLogger.attach(to: overlaysHost.view,
                                       label: "6. page \(pidTag) overlays host")
                #endif

            hosts.append(PageHostState(
                pageId:       page.id,
                frame:        frame,
                renderer:     renderer,
                templateHost: templateHost,
                overlaysHost: overlaysHost,
                template:     page.backgroundTemplate
            ))
            return y + baseSize.height + pageGap
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
                hosts[i].overlaysHost.detachFromParentVC()
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

            // Step 8: read via the in-memory cache first; fall
            // back to the V6 stroke singleton on miss and warm the
            // cache with the decoded drawing for next time.
            if let cached = StrokeCache.shared.drawing(forPage: page.id) {
                canvas.drawing = cached
            } else if let data = StorageService.shared.strokeData(for: page),
                      let drawing = try? PKDrawing(data: data) {
                canvas.drawing = drawing
                StrokeCache.shared.cache(drawing, forPage: page.id)
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

            // Tap-through for interactive elements. While a drawing tool
            // is active the canvas is interaction-enabled and would
            // otherwise swallow every finger tap — including taps on an
            // audio strip's play button or an image/sticky/text element
            // underneath. Yield finger taps that land on such an element
            // to the overlay below; Pencil keeps drawing everywhere.
            let canvasPageId = page.id
            canvas.shouldYieldTouchToOverlay = { [weak self, weak canvas] point, event in
                guard let self, let canvas else { return false }
                // Pencil must always draw — never yield.
                if let touches = event?.allTouches,
                   touches.contains(where: { $0.type == .pencil }) {
                    return false
                }
                // Drawing tools should never yield to the media
                // overlay: the overlay has `allowsHitTesting(false)`
                // while a drawing tool is active, so a yield here
                // strands the finger touch between two views that
                // both refuse it — the user sees the stroke "not
                // taking" until they start from outside the image.
                if self.viewModel.selectedTool.isDrawingTool {
                    return false
                }
                let size = canvas.bounds.size
                guard size.width > 0, size.height > 0 else { return false }
                return self.pointHitsInteractiveElement(
                    point, pageId: canvasPageId, pageSize: size
                )
            }

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

            #if DEBUG
            // Fix 1 — touch-path diagnostic. PKCanvasView is added
            // to `contentView` AFTER each page's `renderer`, so it
            // is a sibling stacked ON TOP of every element overlay —
            // the prime suspect for absorbing element taps. If the
            // `[TouchPath]` sequence reaches "5. PKCanvasView" and
            // stops, this layer is the absorber.
            TouchPathLogger.attach(
                to: canvas,
                label: "5. PKCanvasView page \(hosts[i].pageId.uuidString.prefix(8))"
            )
            #endif

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
            }
        }

        // OPEN_ISSUES #1: `promoteActiveOverlayToFront` is gone. It
        // existed to shuffle the per-tool z-order of nine separate
        // overlay hosts so the right one's tap-catcher reached the
        // front of the renderer's subview stack. With every overlay
        // now inside one `PageOverlaysContainer`, hit routing happens
        // inside a single SwiftUI tree — SwiftUI delivers each tap to
        // the element actually at the point — so a fixed back-to-front
        // ZStack order in the container replaces all of that.
        //
        // The lasso host no longer needs UIKit-layer interaction
        // gating either: `LassoOverlayView` self-gates with
        // `.allowsHitTesting`, which is honoured now that it sits in
        // the same SwiftUI tree as the overlays it must not absorb.

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

        /// True when `point` (in page-pt canvas coordinates) lands on an
        /// **action** widget — currently audio strips and images — on
        /// the given page. Backs the canvas tap-through so a finger tap
        /// on the audio play button or an image's selection handle
        /// reaches the overlay even while the pen tool keeps the canvas
        /// interactive.
        ///
        /// Text and sticky notes are *not* in this set: a tap on them
        /// opens the keyboard for editing, which would steal focus
        /// mid-drawing every time the user tapped over an existing
        /// text block. Editing text deliberately requires the cursor
        /// tool. Strokes/highlights/PDF pages are drawn content, not
        /// tappable widgets, so they're skipped too.
        ///
        /// Runs only on finger touch-down (Pencil short-circuits in
        /// the caller), so the one-shot SwiftData fetch is off the
        /// drawing hot path.
        func pointHitsInteractiveElement(
            _ point: CGPoint,
            pageId: UUID,
            pageSize: CGSize
        ) -> Bool {
            let ctx = StorageService.shared.container.mainContext
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.pageId == pageId && $0.deletedAt == nil
                }
            )
            guard let elements = try? ctx.fetch(descriptor) else { return false }
            for e in elements {
                switch e.kind {
                case .audio, .image:
                    // Clamp to a ≥44pt tap target so a thin/zero-height
                    // element (e.g. a freshly-created strip whose
                    // normalized height hasn't been written yet) is
                    // still reachable.
                    let w = max(e.normalizedWidth  * pageSize.width,  44)
                    let h = max(e.normalizedHeight * pageSize.height, 44)
                    let rect = CGRect(
                        x: e.normalizedX * pageSize.width,
                        y: e.normalizedY * pageSize.height,
                        width: w, height: h
                    )
                    if rect.contains(point) { return true }
                default:
                    break
                }
            }
            return false
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            if !suppressZoomUpdate {
                let z = scrollView.zoomScale
                if abs(viewModel.zoomScale - z) > 0.001 {
                    viewModel.zoomScale = z
                }
            }
            // Re-centre the document as it shrinks/grows under the
            // pinch. `applyContentInset` pads the scroll view so a
            // page narrower than the viewport sits centred rather
            // than pinned to the left edge.
            applyContentInset()
            updateCanvasMembership()
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { snapToEdgesIfClose(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            snapToEdgesIfClose(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Snap to 1.0× when the user releases the pinch within ~8%
            // of native — pinch deceleration tends to land at 0.94 or
            // 1.07 and feel "stuck" off-grid. The snap is animated so
            // it reads as a magnetic click, and a selection-style haptic
            // confirms the rest position.
            let snapTolerance: CGFloat = 0.08
            if abs(scale - 1.0) > 0.001 && abs(scale - 1.0) < snapTolerance {
                suppressZoomUpdate = true
                UIView.animate(withDuration: 0.18, delay: 0,
                               options: [.curveEaseOut, .beginFromCurrentState]) {
                    scrollView.zoomScale = 1.0
                } completion: { _ in
                    self.suppressZoomUpdate = false
                    self.viewModel.zoomScale = 1.0
                    self.applyContentInset()
                    self.snapToEdgesIfClose(scrollView)
                }
                HapticManager.shared.toolSwitched()
                return
            }
            applyContentInset()
            snapToEdgesIfClose(scrollView)
        }

        /// Magnetically snap the document flush to a viewport edge
        /// when the user releases a pan/zoom with that edge within a
        /// small threshold — the page feels like it "clicks" into
        /// place instead of floating a few points off.
        private func snapToEdgesIfClose(_ scrollView: UIScrollView) {
            let threshold: CGFloat = 44
            let inset   = scrollView.contentInset
            let offset  = scrollView.contentOffset

            // Scrollable bounds for each axis (the resting offsets at
            // which an edge sits flush against the viewport).
            let minX = -inset.left
            let maxX = scrollView.contentSize.width + inset.right - scrollView.bounds.width
            let minY = -inset.top
            let maxY = scrollView.contentSize.height + inset.bottom - scrollView.bounds.height

            var target = offset
            if maxX > minX {
                if abs(offset.x - minX) < threshold { target.x = minX }
                else if abs(offset.x - maxX) < threshold { target.x = maxX }
            }
            if maxY > minY {
                if abs(offset.y - minY) < threshold { target.y = minY }
                else if abs(offset.y - maxY) < threshold { target.y = maxY }
            }
            if target != offset {
                scrollView.setContentOffset(target, animated: true)
            }
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

        /// If the just-finished stroke lands in the lower third of the
        /// *last* page's canvas and auto-add is on, silently append a
        /// blank page after it so one is ready below as the user keeps
        /// writing. The append does NOT scroll — the continuous canvas
        /// reveals the new page when the user reaches it. Throttled to
        /// one fire per second so a flurry of small strokes near the
        /// bottom doesn't spawn multiple pages.
        private func considerAutoAddAfterStroke(on canvasView: PKCanvasView) {
            guard viewModel.autoAddEnabled else { return }
            guard let host = hosts.first(where: { $0.canvasView === canvasView }) else { return }
            guard let lastPageId = viewModel.pages.last?.id, host.pageId == lastPageId else { return }
            guard let stroke = canvasView.drawing.strokes.last else { return }
            let canvasHeight = canvasView.bounds.height
            guard canvasHeight > 0 else { return }
            // Lower third (was bottom 15%) so the user doesn't have to
            // crowd the very bottom edge to grow the canvas. The append
            // is silent, so triggering a little early is harmless — the
            // page just sits ready below.
            let threshold = canvasHeight * 0.66
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

        /// Walks the responder chain looking for a UITextView. Used
        /// by the double-tap delegate to leave text-editing touches
        /// alone (single-tap word-select).
        private static func isInsideTextView(_ view: UIView?) -> Bool {
            var node = view
            while let v = node {
                if v is UITextView { return true }
                node = v.superview
            }
            return false
        }

        // MARK: UIGestureRecognizerDelegate (zoom + dismiss)

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // Refuse double-tap zoom and the dismiss-tap on text views —
            // double-tap is word-select, dismiss is handled separately
            // when the tap lands elsewhere.
            if Self.isInsideTextView(touch.view) {
                if gestureRecognizer is UITapGestureRecognizer {
                    return false
                }
            }
            return true
        }

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

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
    /// Canvas prefetch band — one viewport above/below the visible
    /// area so the next page is ready to draw when scroll rests.
    private let warmBandPaddingFactor: CGFloat = 0.5
    /// Overlay hosts are far heavier than PKCanvasView (full SwiftUI
    /// trees per page). Keep overlays on the visible viewport only —
    /// a quarter-screen pad at most — and unmount when pages leave.
    private let overlayWarmBandPaddingFactor: CGFloat = 0.25

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel,
                    fingerDrawingEnabled: resolvedFingerDrawingEnabled,
                    pageGap: pageGap,
                    warmBandPaddingFactor: warmBandPaddingFactor,
                    overlayWarmBandPaddingFactor: overlayWarmBandPaddingFactor)
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
        // iPhone needs to be able to zoom further out than iPad —
        // A4 at 1.0× is ~595pt wide, an iPhone is ~393pt, so the
        // page only fits when zoomScale ≈ 0.66. 0.5× was too high
        // a floor; lowering to 0.3× lets the user pinch to even
        // smaller if they want. iPad keeps the original 0.5× floor.
        scrollView.minimumZoomScale = DeviceCapabilities.isPhoneIdiom ? 0.3 : 0.5
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
        // Allow both finger and pencil touches to drive the pan
        // recognizer — when the active tool is the cursor (or any
        // other non-drawing tool) the PKCanvasView yields its
        // interaction, so Apple Pencil drags need to fall through
        // to the scroll view. Without `.pencil` in this list the
        // pencil silently did nothing in cursor mode.
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.pencil.rawValue)
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

        // Apple Pencil double-tap — single interaction attached to
        // the stable scrollView so the gesture fires regardless of
        // which page's PKCanvasView is mounted. Earlier the
        // interaction was attached per-canvas inside `mountCanvas`,
        // which meant 2–3 instances existed at any moment (one per
        // warm-band canvas); only the most recently-mounted one
        // received events from iOS in practice, and unmounting the
        // active canvas during scroll silently broke double-tap
        // until the user scrolled enough to remount it.
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        scrollView.addInteraction(pencilInteraction)

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
        context.coordinator.deferringInitialPageHostBuild = true
        DispatchQueue.main.async {
            context.coordinator.rebuildPageHosts()
            context.coordinator.deferringInitialPageHostBuild = false
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

        // Dynamic allowedTouchTypes on the scroll's pan recognizer.
        // - Shape tool active: drop .pencil so Pencil drags belong to
        //   the shape-overlay's PencilFingerDragSurface and don't
        //   double-fire scroll + shape-create (this was producing a
        //   page that scrolled while the user tried to draw).
        // - Otherwise: both finger + Pencil scroll — the cursor-mode
        //   Pencil-scroll fix from earlier in this branch.
        let inShapeMode = viewModel.selectedTool.isShapeMode
        let desiredTouchTypes: [NSNumber] = inShapeMode
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            : [NSNumber(value: UITouch.TouchType.direct.rawValue),
               NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        let currentTouchTypes = scrollView.panGestureRecognizer.allowedTouchTypes
        if currentTouchTypes != desiredTouchTypes {
            scrollView.panGestureRecognizer.allowedTouchTypes = desiredTouchTypes
        }

        // Drawing policy + tool propagate to every mounted canvas.
        coord.applyDrawingPolicyToAll(fingerDraws: fingerDraws)
        coord.applyToolToAll(viewModel.selectedTool)
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

        /// iPhone-only — cached `scrollView.bounds.width` from the
        /// last time we forced a fit-to-width zoom. Bounds change
        /// (rotation, sheet present/dismiss, split-view resize) drop
        /// us out of cache and re-fit; otherwise we leave the user's
        /// in-flight zoom alone. iPad never reads this.
        var phoneFitAppliedForWidth: CGFloat = -1

        private let pageGap: CGFloat
        private let warmBandPaddingFactor: CGFloat
        private let overlayWarmBandPaddingFactor: CGFloat

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
            /// Lazily mounted when the page enters the warm band.
            /// `PageOverlaysContainer` is the heaviest per-page cost
            /// (nine overlay types in one SwiftUI tree) — deferring it
            /// keeps editor open + scroll from mounting every page at once.
            var overlaysHost: UIHostingController<PageOverlaysContainer>?
            var template: PageTemplate
            var canvasView: PKCanvasView?  // lazy-mounted when in warm band
            var saveTask: Task<Void, Never>?
            var strokeDecodeTask: Task<Void, Never>?
            var strokeDecodeGeneration: UInt = 0
            var isDirty: Bool = false
        }

        var hosts: [PageHostState] = []
        private var lastSnapshot: [UUID] = []     // page id list, for diffing
        /// Set while `makeUIView`'s deferred initial mount is
        /// pending — blocks `updateUIView` from duplicating it.
        var deferringInitialPageHostBuild = false
        private var lastActivePageId: UUID?
        var suppressZoomUpdate = false
        private var suppressActivePageUpdates = false
        private var isStrokeInProgress = false
        var appliedTool: CeciliasNotesTool?
        private var lastFingerDrawingEnabled: Bool?
        private var lastCanvasInteractive: Bool?
        private var lastMembershipUpdate: CFTimeInterval = 0
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
        private nonisolated(unsafe) var pixelEraserObserver: NSObjectProtocol?
        private nonisolated(unsafe) var imageHandoffObserver: NSObjectProtocol?
        private nonisolated(unsafe) var strokeRewriteObserver: NSObjectProtocol?
        private nonisolated(unsafe) var interactiveRectsObservers: [NSObjectProtocol] = []

        private struct PageInteractiveRects {
            var audio: [CGRect] = []
            var image: [CGRect] = []
        }

        private var interactiveRectCache: [UUID: PageInteractiveRects] = [:]
        /// Stroke snapshots captured at unmount time — flushed after
        /// scroll-rest. Keyed by pageId so a late async flush cannot
        /// overwrite ink the user added after remounting the page.
        private var pendingUnmountDrawings: [UUID: PKDrawing] = [:]
        /// Canvas indices queued while the user is actively scrolling.
        private var pendingCanvasMountIndices = Set<Int>()
        private var pendingCanvasMountTask: Task<Void, Never>?
        /// Overlay hosts deferred until scroll-rest or one-per-tick mount.
        private var pendingOverlayMountIndices = Set<Int>()
        private var pendingOverlayMountTask: Task<Void, Never>?
        /// Remaining page hosts to mount across runloop ticks.
        private var hostBuildQueue: [(page: Page, frame: CGRect)] = []
        private var hostBuildMaxW: CGFloat = 0

        init(viewModel: EditorViewModel,
             fingerDrawingEnabled: Bool,
             pageGap: CGFloat,
             warmBandPaddingFactor: CGFloat,
             overlayWarmBandPaddingFactor: CGFloat) {
            self.viewModel = viewModel
            self.fingerDrawingEnabled = fingerDrawingEnabled
            self.pageGap = pageGap
            self.warmBandPaddingFactor = warmBandPaddingFactor
            self.overlayWarmBandPaddingFactor = overlayWarmBandPaddingFactor
            super.init()
            self.capabilityObserver = NotificationCenter.default.addObserver(
                forName: .inputCapabilityChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // queue: .main delivers on main; assume MainActor to
                // call the @MainActor capability + view-model reads
                // without an extra hop.
                MainActor.assumeIsolated {
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
            // Pixel-eraser width slider rebuilds the PKEraserTool on
            // every mounted canvas. Forced because the selectedTool
            // case doesn't change (.eraser(.pixel) → .eraser(.pixel))
            // — width lives in UserDefaults, which makePKTool reads
            // on every rebuild.
            self.pixelEraserObserver = NotificationCenter.default.addObserver(
                forName: .pixelEraserWidthChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.applyToolToAll(self.viewModel.selectedTool, force: true)
                }
            }
            self.imageHandoffObserver = NotificationCenter.default.addObserver(
                forName: .imageElementCrossPageHandoffRequested,
                object: nil,
                queue: .main
            ) { [weak self] note in
                // queue: .main delivers on the main thread, but
                // `Notification` itself isn't Sendable so we can't
                // capture it into a MainActor closure directly under
                // strict concurrency. Pull the Sendable primitives
                // out *before* the actor hop, then dispatch.
                guard let info = note.userInfo,
                      let elementId = info["elementId"] as? UUID,
                      let sourcePageId = info["currentPageId"] as? UUID,
                      let proposedX = info["proposedNormX"] as? Double,
                      let proposedY = info["proposedNormY"] as? Double
                else { return }
                MainActor.assumeIsolated {
                    self?.handleImageCrossPageHandoff(
                        elementId: elementId,
                        sourcePageId: sourcePageId,
                        proposedNormX: proposedX,
                        proposedNormY: proposedY
                    )
                }
            }
            self.strokeRewriteObserver = NotificationCenter.default.addObserver(
                forName: .strokeContentRewritten,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let pageIds = note.userInfo?["pageIds"] as? [UUID] else { return }
                MainActor.assumeIsolated {
                    self?.cancelPendingSaves(forPageIds: pageIds)
                    self?.reloadCanvases(forPageIds: pageIds)
                }
            }
            for rectCacheNote in [
                Notification.Name.audioElementsChanged,
                .mediaAttachmentsChanged,
                .shapeElementsChanged,
            ] {
                let token = NotificationCenter.default.addObserver(
                    forName: rectCacheNote,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.interactiveRectCache.removeAll()
                    }
                }
                interactiveRectsObservers.append(token)
            }
        }

        deinit {
            if let token = capabilityObserver {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = pixelEraserObserver {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = imageHandoffObserver {
                NotificationCenter.default.removeObserver(token)
            }
            if let token = strokeRewriteObserver {
                NotificationCenter.default.removeObserver(token)
            }
            for token in interactiveRectsObservers {
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
            // `makeUIView` schedules the first mount on the next
            // runloop; `updateUIView` can fire first with an empty
            // host stack and duplicate the full tear-down/rebuild.
            if deferringInitialPageHostBuild && hosts.isEmpty {
                return
            }
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
            let snapshot = viewModel.pages.map(\.id)
            if snapshot == lastSnapshot && !hosts.isEmpty {
                applyPageMetadataChanges()
                return
            }
            hostBuildQueue.removeAll()
            tearDownAllHosts()
            let pages   = viewModel.pages
            let maxW    = pages.map { $0.pageSize.pointSize.width }.max()
                ?? PageSize.a4.pointSize.width
            var y: CGFloat = 0
            var frames: [(Page, CGRect)] = []
            for page in pages {
                let baseSize = page.pageSize.pointSize
                let frame = CGRect(
                    x: (maxW - baseSize.width) / 2,
                    y: y,
                    width: baseSize.width,
                    height: baseSize.height
                )
                frames.append((page, frame))
                y += baseSize.height + pageGap
            }
            updateContentSize(width: maxW, height: max(0, y - pageGap))
            lastSnapshot = pages.map(\.id)
            hostBuildMaxW = maxW
            // Active page first so the first interactive frame lands
            // on the page the user is actually viewing.
            let activeIdx = viewModel.currentPageIndex
            if frames.indices.contains(activeIdx) {
                let active = frames.remove(at: activeIdx)
                frames.insert(active, at: 0)
            }
            hostBuildQueue = frames.map { ($0.0, $0.1) }
            continueHostBuild(batchSize: 1)
        }

        private func continueHostBuild(batchSize: Int) {
            guard contentView != nil else { return }
            let count = min(batchSize, hostBuildQueue.count)
            guard count > 0 else {
                let activeIdx = viewModel.currentPageIndex
                if hosts.indices.contains(activeIdx) {
                    ensureOverlaysMounted(at: activeIdx)
                }
                mountActivePageCanvasFirst()
                DispatchQueue.main.async { [weak self] in
                    self?.updateCanvasMembership(force: true)
                }
                return
            }
            for _ in 0..<count {
                let item = hostBuildQueue.removeFirst()
                mountPageHost(item.page, frame: item.frame, contentMaxWidth: hostBuildMaxW, mountOverlays: false)
            }
            if hostBuildQueue.isEmpty {
                let activeIdx = viewModel.currentPageIndex
                if hosts.indices.contains(activeIdx) {
                    ensureOverlaysMounted(at: activeIdx)
                }
                mountActivePageCanvasFirst()
                DispatchQueue.main.async { [weak self] in
                    self?.updateCanvasMembership(force: true)
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.continueHostBuild(batchSize: batchSize)
                }
            }
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
            let baseSize = page.pageSize.pointSize
            let frame = CGRect(
                x: (maxW - baseSize.width) / 2,
                y: y,
                width: baseSize.width,
                height: baseSize.height
            )
            mountPageHost(page, frame: frame, contentMaxWidth: maxW, mountOverlays: false)
            return y + baseSize.height + pageGap
        }

        private func mountPageHost(
            _ page: Page,
            frame: CGRect,
            contentMaxWidth maxW: CGFloat,
            mountOverlays: Bool = false
        ) {
            guard let contentView else { return }
            let baseSize = page.pageSize.pointSize
            let renderer = PageRenderer(pageSize: page.pageSize)
            renderer.frame = frame

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

                let pageCS = PageCoordinateSpace(baseSize: baseSize)

                contentView.addSubview(renderer)

            var overlaysHost: UIHostingController<PageOverlaysContainer>?
            if mountOverlays {
                overlaysHost = mountOverlaysHost(
                    page: page,
                    renderer: renderer,
                    coordinateSpace: pageCS
                )
            }

            hosts.append(PageHostState(
                pageId:       page.id,
                frame:        frame,
                renderer:     renderer,
                templateHost: templateHost,
                overlaysHost: overlaysHost,
                template:     page.backgroundTemplate
            ))
        }

        private func mountOverlaysHost(
            page: Page,
            renderer: PageRenderer,
            coordinateSpace pageCS: PageCoordinateSpace
        ) -> UIHostingController<PageOverlaysContainer> {
            let inputs = overlayInputs(for: page.id)
            let overlaysHost = UIHostingController(
                rootView: PageOverlaysContainer(
                    viewModel: viewModel,
                    pageId: page.id,
                    notebookId: viewModel.notebook.id,
                    coordinateSpace: pageCS,
                    overlayInputs: inputs
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
            return overlaysHost
        }

        private func overlayInputs(for pageId: UUID) -> EditorPageOverlayInputs {
            EditorPageOverlayInputs(
                selectedTool: viewModel.selectedTool,
                canvasView: viewModel.canvasForPageHandler?(pageId)
            )
        }

        /// Refresh the single active-page overlay when tool / canvas
        /// inputs change without remounting the hosting controller.
        func refreshActivePageOverlayInputs() {
            guard let activeId = lastActivePageId,
                  let i = hosts.firstIndex(where: { $0.pageId == activeId }),
                  let overlaysHost = hosts[i].overlaysHost,
                  let page = page(for: activeId) else { return }
            let inputs = overlayInputs(for: activeId)
            if overlaysHost.rootView.overlayInputs == inputs { return }
            let pageCS = PageCoordinateSpace(baseSize: page.pageSize.pointSize)
            overlaysHost.rootView = PageOverlaysContainer(
                viewModel: viewModel,
                pageId: activeId,
                notebookId: viewModel.notebook.id,
                coordinateSpace: pageCS,
                overlayInputs: inputs
            )
        }

        private func ensureOverlaysMounted(at i: Int) {
            guard hosts.indices.contains(i),
                  hosts[i].overlaysHost == nil,
                  let page = page(for: hosts[i].pageId) else { return }
            let pageCS = PageCoordinateSpace(baseSize: page.pageSize.pointSize)
            hosts[i].overlaysHost = mountOverlaysHost(
                page: page,
                renderer: hosts[i].renderer,
                coordinateSpace: pageCS
            )
        }

        private func unmountOverlays(at i: Int) {
            guard hosts.indices.contains(i),
                  let overlaysHost = hosts[i].overlaysHost else { return }
            pendingOverlayMountIndices.remove(i)
            overlaysHost.detachFromParentVC()
            overlaysHost.view.removeFromSuperview()
            hosts[i].overlaysHost = nil
        }

        private func tearDownAllHosts() {
            hostBuildQueue.removeAll()
            pendingCanvasMountTask?.cancel()
            pendingCanvasMountTask = nil
            pendingCanvasMountIndices.removeAll()
            pendingOverlayMountTask?.cancel()
            pendingOverlayMountTask = nil
            pendingOverlayMountIndices.removeAll()
            flushPendingUnmountSaves()
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
                hosts[i].overlaysHost?.detachFromParentVC()
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
            applyPhoneFitToWidthIfNeeded()
        }

        /// iPhone-only: set the scroll view's zoom so the widest page
        /// fits the visible width with a small safe-area margin. Page
        /// sizes are stored as iPad-class point values (A4 ≈ 595pt,
        /// Letter ≈ 612pt) so without this they overflow the iPhone
        /// screen and text typed into elements lands off-screen.
        ///
        /// Runs once per scrollView bounds change — `phoneFitApplied`
        /// caches the bounds.width we last fit against and is
        /// invalidated by `refreshContentInsetForBounds` (which already
        /// fires on every layout pass). This keeps the user's
        /// subsequent manual zoom in place; we don't ratchet back to
        /// fit-to-width after every page mount.
        private func applyPhoneFitToWidthIfNeeded() {
            guard DeviceCapabilities.isPhoneIdiom,
                  let scrollView,
                  scrollView.bounds.width > 0,
                  scrollView.contentSize.width > 0
            else { return }
            // Already fit against the current bounds — don't override
            // a user pinch.
            if abs(phoneFitAppliedForWidth - scrollView.bounds.width) < 0.5 { return }

            // Aim for 12pt of breathing room on each side so the page
            // edge doesn't kiss the screen edge.
            let target = (scrollView.bounds.width - 24) / scrollView.contentSize.width
            let fit = max(scrollView.minimumZoomScale,
                          min(1.0, target))
            // Suppress scrollViewDidZoom's `viewModel.zoomScale = z`
            // assignment for the duration of the fit-to-width zoom.
            // Without this the delegate fires synchronously during
            // a SwiftUI layout pass (updateContentSize is reached
            // via the host's layoutSubviews hook), the @Published
            // write lands inside the view-update tick, and SwiftUI
            // emits "Publishing changes from within view updates"
            // a dozen times per page swap. The user-driven pinch
            // path still publishes normally.
            suppressZoomUpdate = true
            scrollView.setZoomScale(fit, animated: false)
            suppressZoomUpdate = false
            phoneFitAppliedForWidth = scrollView.bounds.width
            // Re-centre after zoom change.
            applyContentInset()
            // Catch up the view-model now that we're past the layout
            // pass — but defer one runloop tick so the assignment
            // lands outside SwiftUI's update cycle.
            let z = scrollView.zoomScale
            DispatchQueue.main.async { [weak viewModel] in
                guard let vm = viewModel, abs(vm.zoomScale - z) > 0.001 else { return }
                vm.zoomScale = z
            }
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
            // Bounds may have grown / shrunk (rotation, sheet
            // dismiss). Reset the phone fit cache so the next
            // updateContentSize re-fits against the new width.
            // iPad path is a no-op — the function is gated on
            // isPhoneIdiom.
            phoneFitAppliedForWidth = -1
            applyPhoneFitToWidthIfNeeded()
        }

        private func applyContentInset() {
            guard let scrollView else { return }
            // `contentSize` is the UNSCALED content extent. The
            // actually-displayed extent is contentSize × zoomScale —
            // and centering needs to compare to the displayed extent,
            // not the unscaled one. iPad has historically run at
            // zoomScale == 1 so the bug never showed; iPhone fits
            // A4 to screen by setting zoomScale ≈ 0.66, which made
            // the previous "(bounds - contentSize) / 2" formula
            // negative and clamped to 0 — page glued to the left
            // edge instead of centred.
            let scale  = scrollView.zoomScale
            let width  = scrollView.contentSize.width  * scale
            let height = scrollView.contentSize.height * scale
            // Skip when bounds aren't yet sized — the host's
            // `layoutSubviews` will re-fire once SwiftUI gives the
            // representable its real frame.
            guard scrollView.bounds.width > 0, width > 0 else { return }

            // Tool-palette overlay reservation. The vertical pill on
            // a left- or right-edge palette covers ~68pt of the
            // viewport; centering the page in the FULL scrollView
            // bounds leaves it visually pushed under the palette.
            // Subtract the palette-covered strip from the available
            // width, centre the page in what's left, and add the
            // palette strip back to the opposite-side inset.
            //
            // Reserve only the part of the strip the page would
            // actually intrude on. When the page is zoomed out far
            // enough that the true-centre gutter already clears the
            // palette, an unconditional reservation shifted the page
            // ~34pt off-centre — the user read it as "the page leans
            // left." `max(0, strip − gutter)` keeps the page truly
            // centred while it fits, and continuously hands back the
            // full reservation as the page grows under the palette.
            let paletteStrip: CGFloat = 56 + 12   // matches ToolPaletteView
            let trueCentreGutter = (scrollView.bounds.width - width) / 2
            let neededReservation = max(0, paletteStrip - max(0, trueCentreGutter))
            var reservedLeft:  CGFloat = 0
            var reservedRight: CGFloat = 0
            let paletteEdge = paletteEdgeForActiveNotebook(boundsSize: scrollView.bounds.size)
            switch paletteEdge {
            case .left:  reservedLeft  = neededReservation
            case .right: reservedRight = neededReservation
            case .top, .bottom: break
            }
            let availableWidth = scrollView.bounds.width - reservedLeft - reservedRight
            let centeringInset = max(0, (availableWidth - width) / 2)
            let leftInset  = centeringInset + reservedLeft
            let rightInset = centeringInset + reservedRight

            let vInset = max(0, scrollView.bounds.height / 2 - height / 2)
            let newInset = UIEdgeInsets(
                top:    Swift.max(scrollView.bounds.height * 0.10, vInset),
                left:   leftInset,
                bottom: Swift.max(scrollView.bounds.height * 0.10, vInset),
                right:  rightInset
            )
            // Only assign when actually different — setting the
            // inset always triggers a `setContentOffset` adjustment
            // that can fight the user's in-flight scroll.
            if scrollView.contentInset != newInset {
                scrollView.contentInset = newInset
            }
        }

        /// Read the per-notebook palette edge from UserDefaults —
        /// `ToolPaletteView` persists it under
        /// `toolbar.position.<notebookId>` on every drag-end. Default
        /// is `.right` to match the palette's own fallback.
        private func paletteEdgeForActiveNotebook(boundsSize: CGSize) -> ToolbarEdge {
            let key = "toolbar.position.\(viewModel.notebook.id.uuidString)"
            if let raw = UserDefaults.standard.string(forKey: key),
               let edge = ToolbarEdge(rawValue: raw) {
                return edge
            }
            // No saved value → palette uses orientation-derived default.
            return ToolbarEdgeBinding.isLandscape(boundsSize)
                ? ToolbarEdgeBinding.landscapeDefault
                : ToolbarEdgeBinding.portraitDefault
        }

        // MARK: Image cross-page hand-off

        /// Called when an image element's drag carried it past the
        /// top or bottom of its source page. We translate the
        /// proposed coords into the source-page's coordinate frame,
        /// find which mounted page host overlaps that point, and if
        /// it's different from the source page, rewrite the
        /// element's pageId + page relationship + normalizedY for
        /// the destination page's frame. SwiftData change
        /// notifications repaint both overlays automatically.
        func handleImageCrossPageHandoff(
            elementId: UUID,
            sourcePageId: UUID,
            proposedNormX proposedX: Double,
            proposedNormY proposedY: Double
        ) {
            // 1. Resolve the source page host to translate proposed
            //    normalised coords into content-view (continuous-
            //    scroll) coordinates.
            guard let source = hosts.first(where: { $0.pageId == sourcePageId }) else { return }
            let pointInContent = CGPoint(
                x: source.frame.minX + CGFloat(proposedX)  * source.frame.width,
                y: source.frame.minY + CGFloat(proposedY)  * source.frame.height
            )

            // 2. Find the destination host whose frame contains the
            //    projected content-view Y. Horizontal containment is
            //    a softer match — page widths can differ in
            //    mixed-size notebooks; we accept the host as long as
            //    Y lands inside it.
            let dest = hosts.first { host in
                pointInContent.y >= host.frame.minY &&
                pointInContent.y <  host.frame.maxY
            }
            guard let dest, dest.pageId != sourcePageId else { return }

            // 3. Compute the destination-page normalised coords.
            //    Clamp X within [0, 1 - elementW] and Y within
            //    [0, 1 - elementH] once we know the element's size.
            let ctx = StorageService.shared.context
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> { $0.id == elementId }
            )
            guard let element = (try? ctx.fetch(descriptor))?.first else { return }
            let destNormX = max(
                0,
                min(
                    1 - element.normalizedWidth,
                    Double((pointInContent.x - dest.frame.minX) / dest.frame.width)
                )
            )
            let destNormY = max(
                0,
                min(
                    1 - element.normalizedHeight,
                    Double((pointInContent.y - dest.frame.minY) / dest.frame.height)
                )
            )

            element.pageId      = dest.pageId
            element.normalizedX = destNormX
            element.normalizedY = destNormY
            element.updatedAt   = Date()
            do {
                try ctx.save()
            } catch {
                // Failure here strands the element half-moved —
                // the @Bindable model already has the new pageId
                // in memory, but persistence still points at the
                // old page. After the next app launch the element
                // jumps back. Log so a "my image went back to the
                // wrong page" report surfaces in device logs.
                #if DEBUG
                dlog("[CrossPage] handoff SAVE FAILED elementId=\(elementId) sourcePage=\(sourcePageId) destPage=\(dest.pageId): \(error)")
                #endif
            }

            // SwiftData saves on the main context don't drive the
            // overlays here — each per-kind overlay uses a manual
            // `refreshTick` bumped by a `Notification.Name` (the
            // overlays render under per-page UIHostingControllers
            // mounted by this coordinator, so they don't get an
            // injected `@Environment(\.modelContext)` change signal).
            // Without the post below the source overlay keeps
            // painting the element until its next unrelated refresh
            // and the destination overlay misses it entirely — which
            // is the "image won't cross pages" bug for images and
            // the "shape flickers / disappears" symptom for shapes.
            // Post the right kind-specific signal so both ends
            // re-fetch. UserInfo carries source + destination page
            // ids so the source overlay can defer its refresh by
            // one runloop tick — without that, both overlays
            // refresh on the same tick and SwiftUI's render commit
            // briefly shows neither (source has dropped the element
            // already, destination's render of the new mount lands
            // on the next frame). The deferred refresh shifts the
            // ordering so the destination renders FIRST, then the
            // source clears — the user sees the shape jump across
            // pages instead of flickering through an empty frame.
            let userInfo: [AnyHashable: Any] = [
                "sourcePageId": sourcePageId,
                "destPageId":   dest.pageId,
                "elementId":    elementId
            ]
            switch element.kind {
            case .image:
                NotificationCenter.default.post(name: .mediaAttachmentsChanged, object: nil, userInfo: userInfo)
            case .shape:
                NotificationCenter.default.post(name: .shapeElementsChanged, object: nil, userInfo: userInfo)
            case .stickyNote:
                NotificationCenter.default.post(name: .stickyNotesChanged, object: nil, userInfo: userInfo)
            default:
                break
            }
        }

        // MARK: Canvas membership (lazy mount/unmount)

        /// True while the user's finger is down or a flick is
        /// decelerating. During that window `updateCanvasMembership`
        /// runs in a lightweight mode: it mounts only pages entering
        /// the actually-VISIBLE viewport (a canvas the user can see
        /// must exist) and defers warm-band prefetch mounts AND all
        /// unmounts to scroll-rest. Mounting is the expensive step —
        /// PKCanvasView alloc + PKDrawing decode on the main thread
        /// — and running it mid-scroll was the recurring "tiny lag
        /// while resuming smooth scroll" hitch: every page crossing
        /// the padded band cost a frame spike. The full band pass
        /// re-runs from the didEnd callbacks.
        private(set) var isActivelyScrolling = false

        func setActivelyScrolling(_ active: Bool) {
            guard isActivelyScrolling != active else { return }
            isActivelyScrolling = active
            if !active {
                flushPendingCanvasMounts()
                // Settle active page before membership so the single
                // overlay host mounts on the page the user landed on.
                updateActivePageFromScroll(force: true)
                updateCanvasMembership()
                flushPendingOverlayMounts()
                // The throttle may have swallowed the last few
                // scroll ticks — publish the final resting viewport
                // so the minimap doesn't stop a hair off-position.
                if let scrollView {
                    lastViewportPost = CACurrentMediaTime()
                    NotificationCenter.default.post(
                        name: .ceciliasNotesCanvasViewportDidChange,
                        object: nil,
                        userInfo: [
                            "offset": scrollView.contentOffset,
                            "zoom":   scrollView.zoomScale,
                        ]
                    )
                }
            }
        }

        /// Mount only the active page's canvas on the first editor frame;
        /// remaining warm-band pages mount on the next tick.
        private func mountActivePageCanvasFirst() {
            guard let contentView else { return }
            let idx = viewModel.currentPageIndex
            guard hosts.indices.contains(idx),
                  hosts[idx].canvasView == nil else { return }
            ensureOverlaysMounted(at: idx)
            mountCanvas(at: idx, in: contentView)
        }

        func updateCanvasMembership(force: Bool = false) {
            guard let scrollView, let contentView else { return }
            let viewportTop    = scrollView.contentOffset.y
            let viewportBottom = viewportTop + scrollView.bounds.height
            let canvasPad = isActivelyScrolling
                ? 0
                : scrollView.bounds.height * warmBandPaddingFactor
            let overlayPad = isActivelyScrolling
                ? 0
                : scrollView.bounds.height * overlayWarmBandPaddingFactor
            let canvasWarmTop    = viewportTop - canvasPad
            let canvasWarmBottom = viewportBottom + canvasPad
            let overlayWarmTop    = viewportTop - overlayPad
            let overlayWarmBottom = viewportBottom + overlayPad
            var deferredUnmountSaves = false

            for i in hosts.indices {
                let f = hosts[i].frame
                let scale = scrollView.zoomScale
                let scaled = CGRect(
                    x:      f.origin.x * scale,
                    y:      f.origin.y * scale,
                    width:  f.width    * scale,
                    height: f.height   * scale
                )
                let inCanvasBand = scaled.maxY >= canvasWarmTop && scaled.minY <= canvasWarmBottom
                let inOverlayBand = scaled.maxY >= overlayWarmTop && scaled.minY <= overlayWarmBottom
                if inCanvasBand {
                    if hosts[i].canvasView == nil {
                        if isActivelyScrolling {
                            pendingCanvasMountIndices.insert(i)
                        } else {
                            mountCanvas(at: i, in: contentView)
                        }
                    }
                } else if !inCanvasBand && hosts[i].canvasView != nil && !force
                            && !isActivelyScrolling {
                    unmountCanvas(at: i, deferStorageSave: true)
                    deferredUnmountSaves = true
                }
                if inOverlayBand, hosts[i].pageId == lastActivePageId {
                    if hosts[i].overlaysHost == nil {
                        pendingOverlayMountIndices.insert(i)
                    }
                } else if hosts[i].overlaysHost != nil && !force
                            && !isActivelyScrolling {
                    unmountOverlays(at: i)
                }
            }
            if !isActivelyScrolling {
                flushPendingOverlayMounts()
            }
            if deferredUnmountSaves {
                flushPendingUnmountSaves()
            }
        }

        private func flushPendingCanvasMounts() {
            guard !pendingCanvasMountIndices.isEmpty else { return }
            let indices = pendingCanvasMountIndices
            pendingCanvasMountIndices.removeAll()
            scheduleCanvasMounts(indices)
        }

        /// Mount at most one PKCanvasView per runloop tick so scroll-
        /// rest cannot spike the main thread decoding every warm-band
        /// page in a single frame.
        private func scheduleCanvasMounts(_ indices: Set<Int>) {
            guard let contentView, !indices.isEmpty else { return }
            pendingCanvasMountTask?.cancel()
            var queue = indices.sorted()
            pendingCanvasMountTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !queue.isEmpty {
                    guard !Task.isCancelled else { return }
                    let i = queue.removeFirst()
                    guard self.hosts.indices.contains(i),
                          self.hosts[i].canvasView == nil else { continue }
                    self.mountCanvas(at: i, in: contentView)
                    if queue.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }

        private func flushPendingOverlayMounts() {
            guard !pendingOverlayMountIndices.isEmpty else { return }
            let indices = pendingOverlayMountIndices
            pendingOverlayMountIndices.removeAll()
            scheduleOverlayMounts(indices)
        }

        /// Mount at most one `PageOverlaysContainer` per runloop tick
        /// so scrolling through a long notebook cannot wedge the main
        /// thread mounting every overlay tree in one frame.
        private func scheduleOverlayMounts(_ indices: Set<Int>) {
            guard !indices.isEmpty else { return }
            pendingOverlayMountTask?.cancel()
            var queue = indices.sorted()
            pendingOverlayMountTask = Task { @MainActor [weak self] in
                guard let self else { return }
                while !queue.isEmpty {
                    guard !Task.isCancelled else { return }
                    let i = queue.removeFirst()
                    self.ensureOverlaysMounted(at: i)
                    if queue.isEmpty { break }
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }
        }

        private func mountCanvas(at i: Int, in contentView: UIView) {
            guard i < hosts.count else { return }
            guard let page = page(for: hosts[i].pageId) else { return }
            let pageId = hosts[i].pageId
            // A remount supersedes any deferred unmount snapshot.
            pendingUnmountDrawings.removeValue(forKey: pageId)
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
            if let cached = StrokeCache.shared.drawing(forPage: pageId) {
                canvas.drawing = cached
            } else if let data = StorageService.shared.strokeData(for: page),
                      !data.isEmpty {
                canvas.drawing = PKDrawing()
                hosts[i].strokeDecodeTask?.cancel()
                hosts[i].strokeDecodeGeneration &+= 1
                let generation = hosts[i].strokeDecodeGeneration
                hosts[i].strokeDecodeTask = Task.detached(priority: .userInitiated) { [weak canvas] in
                    guard let drawing = try? PKDrawing(data: data) else { return }
                    await MainActor.run { [weak self, weak canvas] in
                        guard let self, let canvas,
                              i < self.hosts.count,
                              self.hosts[i].strokeDecodeGeneration == generation,
                              !self.hosts[i].isDirty,
                              self.hosts[i].canvasView === canvas,
                              canvas.superview != nil
                        else { return }
                        canvas.drawing = drawing
                        StrokeCache.shared.cache(drawing, forPage: pageId)
                    }
                }
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
                let size = canvas.bounds.size
                guard size.width > 0, size.height > 0 else { return false }
                // Audio play buttons must work under drawing tools.
                if self.pointHitsAudioElement(
                    point, pageId: canvasPageId, pageSize: size
                ) {
                    return true
                }
                // Drawing tools should never yield to image overlays:
                // the overlay has `allowsHitTesting(false)` while a
                // drawing tool is active, so a yield here strands the
                // finger touch between two views that both refuse it.
                if self.viewModel.selectedTool.isDrawingTool {
                    return false
                }
                return self.pointHitsImageElement(
                    point, pageId: canvasPageId, pageSize: size
                )
            }

            // Pencil double-tap is now wired ONCE at the scrollView
            // level during `makeUIView` — no per-canvas interaction
            // here. Attaching one interaction per warm-band canvas
            // produced silent dropouts when the active canvas
            // unmounted during scroll.

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
                refreshActivePageOverlayInputs()
            }
        }

        private func unmountCanvas(at i: Int, deferStorageSave: Bool = false) {
            guard i < hosts.count, let canvas = hosts[i].canvasView else { return }
            let pageId = hosts[i].pageId
            if hosts[i].isDirty {
                let drawing = canvas.drawing
                StrokeCache.shared.cache(drawing, forPage: pageId)
                hosts[i].isDirty = false
                if deferStorageSave {
                    pendingUnmountDrawings[pageId] = drawing
                } else if let page = page(for: pageId) {
                    viewModel.savePage(page, drawing: drawing)
                }
            }
            hosts[i].saveTask?.cancel()
            hosts[i].saveTask = nil
            hosts[i].strokeDecodeTask?.cancel()
            hosts[i].strokeDecodeTask = nil
            canvas.removeFromSuperview()
            hosts[i].canvasView = nil
            if viewModel.canvasView === canvas {
                viewModel.canvasView = nil
            }
        }

        private func flushPendingUnmountSaves() {
            guard !pendingUnmountDrawings.isEmpty else { return }
            let snapshots = pendingUnmountDrawings
            pendingUnmountDrawings.removeAll()
            for (pageId, snapshot) in snapshots {
                if let i = hosts.firstIndex(where: { $0.pageId == pageId }),
                   let canvas = hosts[i].canvasView {
                    if hosts[i].isDirty, let page = page(for: pageId) {
                        let live = canvas.drawing
                        StrokeCache.shared.cache(live, forPage: pageId)
                        viewModel.savePage(page, drawing: live)
                        hosts[i].isDirty = false
                    }
                    continue
                }
                guard let page = page(for: pageId) else { continue }
                StrokeCache.shared.cache(snapshot, forPage: pageId)
                viewModel.savePage(page, drawing: snapshot)
            }
        }

        private func cachedInteractiveRects(
            for pageId: UUID,
            pageSize: CGSize
        ) -> PageInteractiveRects {
            if let cached = interactiveRectCache[pageId] { return cached }
            let ctx = StorageService.shared.container.mainContext
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.pageId == pageId && $0.deletedAt == nil
                }
            )
            let elements = (try? ctx.fetch(descriptor)) ?? []
            var rects = PageInteractiveRects()
            for e in elements {
                let w = max(e.normalizedWidth  * pageSize.width,  44)
                let h = max(e.normalizedHeight * pageSize.height, 44)
                let rect = CGRect(
                    x: e.normalizedX * pageSize.width,
                    y: e.normalizedY * pageSize.height,
                    width: w, height: h
                )
                switch e.kind {
                case .audio: rects.audio.append(rect)
                case .image: rects.image.append(rect)
                default: break
                }
            }
            interactiveRectCache[pageId] = rects
            return rects
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
            guard force || activeId != lastActivePageId else { return }

            let previousActiveId = lastActivePageId
            lastActivePageId = activeId
            if let canvas = hosts[bestIdx].canvasView {
                viewModel.canvasView = canvas
            }

            // Drop the overlay for the page we're leaving mid-scroll —
            // remounts on scroll-rest for the landing page only.
            if isActivelyScrolling,
               let prev = previousActiveId,
               prev != activeId,
               let prevIdx = hosts.firstIndex(where: { $0.pageId == prev }),
               hosts[prevIdx].overlaysHost != nil {
                unmountOverlays(at: prevIdx)
            }

            // While the user is actively scrolling, skip @Published
            // `currentPageIndex` writes — they re-render every mounted
            // `PageOverlaysContainer` (@ObservedObject viewModel) on
            // every tick and have produced scroll-time ANRs.
            guard !isActivelyScrolling || force else { return }

            if viewModel.currentPageIndex != bestIdx {
                viewModel.currentPageIndex = bestIdx
            }
            installOverlayLayerIntoActivePage(animated: !force)
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

        func applyToolToAll(_ tool: CeciliasNotesTool, force: Bool = false) {
            if !force, appliedTool == tool { return }
            appliedTool = tool
            for h in hosts {
                if let canvas = h.canvasView { applyTool(tool, to: canvas) }
            }
            refreshActivePageOverlayInputs()
        }

        func applyDrawingPolicyToAll(fingerDraws: Bool) {
            if lastFingerDrawingEnabled == fingerDraws { return }
            lastFingerDrawingEnabled = fingerDraws
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
            if lastCanvasInteractive == desired { return }
            lastCanvasInteractive = desired
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
                // Ruler is not a PKTool — it overlays a ruler edge
                // on the canvas while the *active* ink tool draws
                // along it. Without an inking tool set, the canvas
                // keeps whatever PKTool it had before (often a stale
                // pen colour the user can't reach with the picker
                // since ruler is selected). Apply the last drawing
                // tool so the colour swatches stay live: the user
                // edits the pen settings via the secondary picker
                // and the ruler-guided stroke inherits them.
                let companion = viewModel.lastDrawingToolBeforeRuler ?? viewModel.selectedTool
                if companion.isDrawingTool {
                    canvasView.tool = companion.makePKTool()
                }
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
            viewModel.canvasForPageHandler = { [weak self] pageId in
                self?.hosts.first(where: { $0.pageId == pageId })?.canvasView
            }
            viewModel.canvasHasDirtyPagesHandler = { [weak self] in
                self?.hosts.contains(where: { $0.isDirty }) ?? false
            }
        }

        private func cancelPendingSaves(forPageIds pageIds: [UUID]) {
            for pid in pageIds {
                guard let i = hosts.firstIndex(where: { $0.pageId == pid }) else { continue }
                hosts[i].saveTask?.cancel()
                hosts[i].saveTask = nil
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

        /// Reload the mounted PKCanvasViews for pages whose
        /// `StrokeContent` was rewritten outside PencilKit (lasso
        /// move / scale / rotate / delete). Without this the live
        /// canvas keeps rendering the pre-edit drawing, and its next
        /// debounced save would clobber the lasso edit in the model.
        /// Cache first (the lasso ops write through it), storage
        /// fallback, empty drawing when the stroke element is gone
        /// (whole-element delete).
        func reloadCanvases(forPageIds pageIds: [UUID]) {
            for pid in pageIds {
                guard let i = hosts.firstIndex(where: { $0.pageId == pid }),
                      let canvas = hosts[i].canvasView else { continue }
                // Never clobber in-flight ink — lasso only runs in
                // cursor mode, not during an active stroke.
                if hosts[i].isDirty { continue }
                hosts[i].saveTask?.cancel()
                hosts[i].saveTask = nil
                hosts[i].isDirty = false
                if let cached = StrokeCache.shared.drawing(forPage: pid) {
                    canvas.drawing = cached
                } else if let page = page(for: pid),
                          let data = StorageService.shared.strokeData(for: page),
                          let drawing = try? PKDrawing(data: data) {
                    canvas.drawing = drawing
                    StrokeCache.shared.cache(drawing, forPage: pid)
                } else {
                    canvas.drawing = PKDrawing()
                }
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
        func pointHitsAudioElement(
            _ point: CGPoint,
            pageId: UUID,
            pageSize: CGSize
        ) -> Bool {
            cachedInteractiveRects(for: pageId, pageSize: pageSize).audio
                .contains { $0.contains(point) }
        }

        func pointHitsImageElement(
            _ point: CGPoint,
            pageId: UUID,
            pageSize: CGSize
        ) -> Bool {
            cachedInteractiveRects(for: pageId, pageSize: pageSize).image
                .contains { $0.contains(point) }
        }

        private func elementRects(
            on pageId: UUID,
            pageSize: CGSize,
            kinds: Set<ElementKind>
        ) -> [CGRect] {
            let cached = cachedInteractiveRects(for: pageId, pageSize: pageSize)
            if kinds.contains(.audio), kinds.contains(.image) {
                return cached.audio + cached.image
            }
            if kinds.contains(.audio) { return cached.audio }
            if kinds.contains(.image) { return cached.image }
            return []
        }

        /// Legacy wrapper — yields finger taps on audio (always) and
        /// images (non-drawing tools only).
        func pointHitsInteractiveElement(
            _ point: CGPoint,
            pageId: UUID,
            pageSize: CGSize
        ) -> Bool {
            pointHitsAudioElement(point, pageId: pageId, pageSize: pageSize)
                || pointHitsImageElement(point, pageId: pageId, pageSize: pageSize)
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

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            setActivelyScrolling(true)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                setActivelyScrolling(false)
                snapToEdgesIfClose(scrollView)
            }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            setActivelyScrolling(false)
            snapToEdgesIfClose(scrollView)
        }

        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
            // Magnetic snap: native 1.0× AND the device-specific
            // "fit the whole page" zoom both feel like rest points
            // to the user. Pinch deceleration tends to land just
            // off-grid (0.94 / 1.07 / 0.62) and feel "stuck"; an
            // animated snap turns the off-grid landing into a
            // click. Tolerance is 10% on each target so the snap
            // is discoverable without fighting an intentional zoom.
            let snapTolerance: CGFloat = 0.10
            let fitTarget = currentFitZoom(scrollView)
            var snapTo: CGFloat? = nil
            // Prefer 1.0 when it's near the user's release zoom —
            // it's the "everything at native size" rest point.
            if abs(scale - 1.0) > 0.001 && abs(scale - 1.0) < snapTolerance {
                snapTo = 1.0
            }
            // …then the fit-to-viewport zoom (the value iPhone
            // settles to on first open of a page). On iPad this is
            // usually also 1.0 so it collapses to the same branch;
            // on iPhone it sits around 0.66 and is the user's
            // "show me the whole page" rest point.
            if snapTo == nil,
               let fit = fitTarget,
               abs(scale - fit) > 0.001,
               abs(scale - fit) < snapTolerance {
                snapTo = fit
            }
            if let target = snapTo {
                suppressZoomUpdate = true
                UIView.animate(withDuration: 0.18, delay: 0,
                               options: [.curveEaseOut, .beginFromCurrentState]) {
                    scrollView.zoomScale = target
                } completion: { _ in
                    self.suppressZoomUpdate = false
                    self.viewModel.zoomScale = target
                    self.applyContentInset()
                    self.snapToEdgesIfClose(scrollView)
                }
                HapticManager.shared.toolSwitched()
                return
            }
            applyContentInset()
            snapToEdgesIfClose(scrollView)
        }

        /// The zoom that fits the page width to the viewport,
        /// minus a small breathing margin. Mirrors the formula in
        /// `applyPhoneFitToWidthIfNeeded`. Returns `nil` when the
        /// scrollView hasn't been laid out yet.
        private func currentFitZoom(_ scrollView: UIScrollView) -> CGFloat? {
            guard scrollView.bounds.width > 0,
                  scrollView.contentSize.width > 0 else { return nil }
            let target = (scrollView.bounds.width - 24) / scrollView.contentSize.width
            return max(scrollView.minimumZoomScale, min(1.0, target))
        }

        /// Magnetically snap the document flush to a viewport edge
        /// when the user releases a pan/zoom with that edge within a
        /// small threshold — the page feels like it "clicks" into
        /// place instead of floating a few points off.
        private func snapToEdgesIfClose(_ scrollView: UIScrollView) {
            let threshold: CGFloat = 44
            let inset   = scrollView.contentInset
            let offset  = scrollView.contentOffset
            // contentSize is the UNSCALED base extent; multiply by
            // zoomScale to get the actually-displayed size, which is
            // what the scroll-range math needs.
            let scale   = scrollView.zoomScale

            // Scrollable bounds for each axis (the resting offsets at
            // which an edge sits flush against the viewport).
            let minX = -inset.left
            let maxX = scrollView.contentSize.width * scale + inset.right - scrollView.bounds.width
            let minY = -inset.top
            let maxY = scrollView.contentSize.height * scale + inset.bottom - scrollView.bounds.height

            var target = offset
            if maxX > minX {
                if abs(offset.x - minX) < threshold { target.x = minX }
                else if abs(offset.x - maxX) < threshold { target.x = maxX }
            } else if abs(offset.x - minX) < threshold {
                // Content fits horizontally (page narrower than viewport
                // after insets). Snap to the centred position so a
                // slightly-drifted offset from zoom in/out is corrected.
                target.x = minX
            }
            if maxY > minY {
                if abs(offset.y - minY) < threshold { target.y = minY }
                else if abs(offset.y - maxY) < threshold { target.y = maxY }
            }
            if target != offset {
                scrollView.setContentOffset(target, animated: true)
            }
        }

        /// Last time the viewport notification was posted — the
        /// minimap (its only consumer) throttles to ~15fps anyway,
        /// so posting on every 120Hz scroll tick just burned main-
        /// thread time on dictionary allocs + delivery.
        private var lastViewportPost: CFTimeInterval = 0

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            let now = CACurrentMediaTime()
            if now - lastViewportPost > (1.0 / 30.0) {
                lastViewportPost = now
                NotificationCenter.default.post(
                    name: .ceciliasNotesCanvasViewportDidChange,
                    object: nil,
                    userInfo: [
                        "offset": scrollView.contentOffset,
                        "zoom":   scrollView.zoomScale,
                    ]
                )
            }
            // Membership scans every host frame — throttle to ~10 Hz
            // while actively scrolling so scroll ticks don't wedge the
            // main thread on band math + pending-mount bookkeeping.
            if isActivelyScrolling {
                if now - lastMembershipUpdate > 0.1 {
                    lastMembershipUpdate = now
                    updateCanvasMembership()
                }
            } else {
                updateCanvasMembership()
            }
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
            let hostPageId = hosts.first(where: { $0.canvasView === canvasView })?.pageId
            if hostPageId == lastActivePageId {
                viewModel.canvasView = canvasView
            }
            viewModel.handleStrokeEnded(on: canvasView, pageId: hostPageId)
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

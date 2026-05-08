import PencilKit
import SwiftUI
import UIKit

/// Hosts the writing surface. Composition (back-to-front):
///   UIScrollView                — pan (two fingers only) + pinch
///   └── contentView             — wraps both renderer and canvas; this is what zooms
///       ├── PageRenderer        — paper colour + template via Core Graphics
///       └── PKCanvasView        — drawing surface (finger + Apple Pencil)
///
/// **Critical invariants** (do not break these without re-reading the spec):
///   • drawingPolicy = .anyInput                   (finger and Pencil both draw)
///   • scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
///                                                 (single-touch drags reach the canvas)
///   • scrollView.panGestureRecognizer.allowedTouchTypes excludes .stylus
///                                                 (Pencil never pans)
///   • canvasView.isScrollEnabled = false          (outer UIScrollView handles scroll)
///   • PKCanvasView is created exactly once and reused across all page swaps
///     — only `canvasView.drawing` is reassigned. PKCanvasView spin-up is expensive
///       and must not appear on the per-page hot path.
///   • All save work is debounced and dispatched off the drawing thread.
struct CanvasContainerView: UIViewRepresentable {

    @ObservedObject var viewModel: EditorViewModel

    /// Mirrors `SettingsViewModel.fingerDrawingEnabled`. Default false — Pencil
    /// draws and finger pans/zooms. UserDefaults is the single source of truth
    /// so the canvas wrapper does not require Settings injection.
    @AppStorage("ink.canvas.fingerDrawingEnabled") private var fingerDrawingEnabled: Bool = false

    // MARK: UIViewRepresentable

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel)
    }

    func makeUIView(context: Context) -> UIView {
        // Outer host — provides a stable backdrop colour.
        // Leave translatesAutoresizingMaskIntoConstraints at its default (true) so
        // SwiftUI's frame assignments cascade to autoresizing subviews. Setting
        // it to false here previously stranded the inner UIScrollView at 0×0
        // because Auto Layout had no anchor to re-resolve when the host got sized.
        let host = UIView()
        host.backgroundColor = .inkBackgroundSecondary
        host.isUserInteractionEnabled = true

        // Scroll view (handles all pan + pinch from finger touches).
        // Use autoresizing — diagnostic dump showed Auto Layout constraints failing
        // to resolve under SwiftUI's frame-driven sizing, leaving scrollView at 0×0
        // and breaking hit testing for the entire canvas subtree.
        let scrollView = UIScrollView(frame: host.bounds)
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.isUserInteractionEnabled = true
        scrollView.backgroundColor = .clear
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 4.0
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delegate = context.coordinator
        scrollView.decelerationRate = .normal

        // ── Pan gesture configuration depends on whether finger drawing is on.
        //   Apple Pencil is always banned from the pan recogniser so the stylus
        //   never accidentally pans. The single-touch ↔ two-touch flip is what
        //   gates whether a finger drag scrolls or draws. See applyPanGestureConfig.
        scrollView.delaysContentTouches = false
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue)
        ]
        applyPanGestureConfig(scrollView, fingerDraws: fingerDrawingEnabled)
        host.addSubview(scrollView)

        // Content view — both PageRenderer and PKCanvasView are sized to the page
        // and live as children. The contentView is what the scroll view zooms.
        let pageSize = viewModel.currentPage.pageSize.pointSize
        let contentView = UIView(frame: CGRect(origin: .zero, size: pageSize))
        contentView.backgroundColor = .clear
        contentView.isUserInteractionEnabled = true
        scrollView.addSubview(contentView)
        scrollView.contentSize = pageSize

        // Page renderer — drawn behind the canvas
        let renderer = PageRenderer(
            pageSize: viewModel.currentPage.pageSize,
            template: viewModel.currentPage.backgroundTemplate
        )
        renderer.frame = CGRect(origin: .zero, size: pageSize)
        contentView.addSubview(renderer)

        // PKCanvasView — the writing surface. Created exactly once.
        let canvasView = PKCanvasView(frame: CGRect(origin: .zero, size: pageSize))
        configureCanvas(canvasView)
        canvasView.delegate = context.coordinator
        contentView.addSubview(canvasView)

        // Media attachment overlay — below text blocks, above canvas strokes.
        let mediaOverlayHosting = UIHostingController(
            rootView: MediaAttachmentOverlayView(viewModel: viewModel)
        )
        mediaOverlayHosting.view.frame = CGRect(origin: .zero, size: pageSize)
        mediaOverlayHosting.view.backgroundColor = .clear
        mediaOverlayHosting.view.isUserInteractionEnabled = false   // ContentLayerGestureController gates
        if let parentVC = host.findParentViewController() {
            parentVC.addChild(mediaOverlayHosting)
            contentView.addSubview(mediaOverlayHosting.view)
            mediaOverlayHosting.didMove(toParent: parentVC)
        } else {
            contentView.addSubview(mediaOverlayHosting.view)
        }
        context.coordinator.mediaOverlayHosting = mediaOverlayHosting

        // Text block overlay — above media attachments.
        let overlayHosting = UIHostingController(
            rootView: TextBlockOverlayView(viewModel: viewModel)
        )
        overlayHosting.view.frame = CGRect(origin: .zero, size: pageSize)
        overlayHosting.view.backgroundColor = .clear
        overlayHosting.view.isUserInteractionEnabled = false   // ContentLayerGestureController gates
        if let parentVC = host.findParentViewController() {
            parentVC.addChild(overlayHosting)
            contentView.addSubview(overlayHosting.view)
            overlayHosting.didMove(toParent: parentVC)
        } else {
            contentView.addSubview(overlayHosting.view)
        }
        context.coordinator.textOverlayHosting = overlayHosting

        // Audio annotation pins overlay — above all content, always interactive.
        // Wrapped in AudioPassthroughContainer to prevent the UIHostingController.view
        // from absorbing every touch via UIKit's default "return self" hitTest fallback.
        let audioOverlayHosting = UIHostingController(
            rootView: AudioAnnotationPinsOverlayView(viewModel: viewModel, pageSize: pageSize)
        )
        audioOverlayHosting.view.frame = CGRect(origin: .zero, size: pageSize)
        audioOverlayHosting.view.backgroundColor = .clear
        audioOverlayHosting.view.isUserInteractionEnabled = true

        let audioContainer = AudioPassthroughContainer(frame: CGRect(origin: .zero, size: pageSize))
        audioContainer.backgroundColor = .clear
        audioContainer.addSubview(audioOverlayHosting.view)
        if let parentVC = host.findParentViewController() {
            parentVC.addChild(audioOverlayHosting)
            contentView.addSubview(audioContainer)
            audioOverlayHosting.didMove(toParent: parentVC)
        } else {
            contentView.addSubview(audioContainer)
        }
        context.coordinator.audioOverlayHosting = audioOverlayHosting
        context.coordinator.audioContainer      = audioContainer

        // ContentLayerGestureController — single gate for all finger routing.
        let gestureController = ContentLayerGestureController(frame: CGRect(origin: .zero, size: pageSize))
        gestureController.textOverlay  = overlayHosting.view
        gestureController.mediaOverlay = mediaOverlayHosting.view
        gestureController.audioOverlay = audioContainer   // point at passthrough wrapper, not hosting view
        gestureController.isTextMode              = viewModel.selectedTool.isTextMode
        gestureController.isMediaInteractionEnabled = viewModel.selectedTool.isMediaInteractive
        contentView.addSubview(gestureController)
        context.coordinator.gestureController = gestureController

        // Pencil double-tap interaction
        let pencilInteraction = UIPencilInteraction()
        pencilInteraction.delegate = context.coordinator
        canvasView.addInteraction(pencilInteraction)

        // Two-finger horizontal swipe for page navigation
        let swipeLeft = UISwipeGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipeLeft)
        )
        swipeLeft.direction = .left
        swipeLeft.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(swipeLeft)

        let swipeRight = UISwipeGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleSwipeRight)
        )
        swipeRight.direction = .right
        swipeRight.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(swipeRight)

        // Single-finger double tap → fit-to-width.
        // cancelsTouchesInView = false so the recogniser's 0.35 s wait window
        // doesn't delay the first drawing stroke while it decides "is this a double-tap?".
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap)
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.numberOfTouchesRequired = 1
        doubleTap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(doubleTap)

        // Two-finger double tap → 100%
        let twoFingerDoubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTwoFingerDoubleTap)
        )
        twoFingerDoubleTap.numberOfTapsRequired = 2
        twoFingerDoubleTap.numberOfTouchesRequired = 2
        scrollView.addGestureRecognizer(twoFingerDoubleTap)

        // Wire up coordinator references
        context.coordinator.host        = host
        context.coordinator.scrollView  = scrollView
        context.coordinator.contentView = contentView
        context.coordinator.renderer    = renderer
        context.coordinator.canvasView  = canvasView

        // Hand the canvas reference back to the ViewModel so it can swap drawings
        // and trigger flush-saves without going through the SwiftUI representable.
        viewModel.canvasView = canvasView

        // Load initial drawing (off the main thread? — no: PKDrawing init is cheap and
        // the canvas is empty until we assign, so we do it inline here.)
        if let data = viewModel.currentPage.strokeData,
           let drawing = try? PKDrawing(data: data) {
            canvasView.drawing = drawing
        }

        // Defensive default tool — guarantees the canvas has *some* PKTool set
        // before the first touch arrives. Overwritten immediately by applyTool.
        canvasView.tool = PKInkingTool(.pen, color: .black, width: 2)

        // Apply initial tool from the ViewModel
        applyTool(viewModel.selectedTool, to: canvasView)

        // Defer initial layout to the next runloop so bounds settle.
        DispatchQueue.main.async {
            context.coordinator.centerContent(animated: false)
        }

        return host
    }

    func updateUIView(_ host: UIView, context: Context) {
        let coord = context.coordinator
        guard let canvasView = coord.canvasView,
              let renderer   = coord.renderer,
              let contentView = coord.contentView,
              let scrollView  = coord.scrollView else { return }

        // 0. Hit-testing + input-policy invariants — re-asserted every update so
        //    a SwiftUI re-render, modifier change, or Settings toggle is reflected
        //    on the live canvas without recreating the view.
        canvasView.isUserInteractionEnabled = true
        let desiredPolicy: PKCanvasViewDrawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        if canvasView.drawingPolicy != desiredPolicy {
            canvasView.drawingPolicy = desiredPolicy
        }
        // Only mutate the pan recogniser when the touch-count requirement
        // actually changes — touching it during an active gesture interrupts
        // PKCanvasView's stroke commit.
        let desiredTouches = fingerDrawingEnabled ? 2 : 1
        if scrollView.panGestureRecognizer.minimumNumberOfTouches != desiredTouches {
            scrollView.panGestureRecognizer.minimumNumberOfTouches = desiredTouches
        }

        // 1. Tool change
        if context.coordinator.appliedTool != viewModel.selectedTool {
            applyTool(viewModel.selectedTool, to: canvasView)
            context.coordinator.appliedTool = viewModel.selectedTool
            // Sync content layer gate — pencil always draws regardless.
            let isText  = viewModel.selectedTool.isTextMode
            let isMedia = viewModel.selectedTool.isMediaInteractive
            context.coordinator.gestureController?.isTextMode               = isText
            context.coordinator.gestureController?.isMediaInteractionEnabled = isMedia
            context.coordinator.textOverlayHosting?.view.isUserInteractionEnabled  = isText
            context.coordinator.mediaOverlayHosting?.view.isUserInteractionEnabled = isMedia
        }

        // 2. Page change — swap drawing only. Never recreate canvasView.
        if context.coordinator.appliedPageId != viewModel.currentPage.id {
            let page = viewModel.currentPage
            renderer.update(pageSize: page.pageSize, template: page.backgroundTemplate)

            let newSize = page.pageSize.pointSize
            renderer.frame    = CGRect(origin: .zero, size: newSize)
            canvasView.frame  = CGRect(origin: .zero, size: newSize)
            contentView.frame = CGRect(origin: contentView.frame.origin, size: newSize)
            scrollView.contentSize = newSize
            context.coordinator.mediaOverlayHosting?.view.frame = CGRect(origin: .zero, size: newSize)
            context.coordinator.textOverlayHosting?.view.frame  = CGRect(origin: .zero, size: newSize)
            context.coordinator.audioOverlayHosting?.view.frame = CGRect(origin: .zero, size: newSize)
            context.coordinator.audioOverlayHosting?.rootView   = AudioAnnotationPinsOverlayView(viewModel: viewModel, pageSize: newSize)
            context.coordinator.audioContainer?.frame            = CGRect(origin: .zero, size: newSize)
            context.coordinator.gestureController?.frame         = CGRect(origin: .zero, size: newSize)

            if let data = page.strokeData, let drawing = try? PKDrawing(data: data) {
                canvasView.drawing = drawing
            } else {
                canvasView.drawing = PKDrawing()
            }

            // Reset undo scope so previous-page edits are not in this page's undo manager.
            canvasView.undoManager?.removeAllActions()

            context.coordinator.appliedPageId = page.id
            DispatchQueue.main.async { coord.centerContent(animated: false) }
        }

        // 3. Programmatic zoom request from ViewModel (e.g. minimap tap)
        if abs(scrollView.zoomScale - viewModel.zoomScale) > 0.001 {
            // Avoid feedback loops — scrollViewDidZoom updates ViewModel
            // only sets when *we* changed it.
            if !context.coordinator.suppressZoomUpdate {
                context.coordinator.suppressZoomUpdate = true
                scrollView.setZoomScale(viewModel.zoomScale, animated: false)
                context.coordinator.suppressZoomUpdate = false
            }
        }
    }

    // MARK: Helpers

    private func configureCanvas(_ canvasView: PKCanvasView) {
        canvasView.translatesAutoresizingMaskIntoConstraints = true
        canvasView.isUserInteractionEnabled = true
        // drawingPolicy mirrors the user's "Finger Drawing" setting. Default off
        // → only Apple Pencil draws; finger is for scroll/zoom.
        canvasView.drawingPolicy = fingerDrawingEnabled ? .anyInput : .pencilOnly
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        canvasView.isScrollEnabled = false
        canvasView.showsVerticalScrollIndicator   = false
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.alwaysBounceVertical   = false
        canvasView.alwaysBounceHorizontal = false
        canvasView.maximumZoomScale = 1
        canvasView.minimumZoomScale = 1
        canvasView.contentInsetAdjustmentBehavior = .never
    }

    /// Sets the outer scroll view's pan recogniser to whichever touch count is
    /// appropriate for the current finger-drawing mode.
    ///   • fingerDraws == true  → minimumNumberOfTouches = 2
    ///       Single finger draws (PKCanvasView claims it). Two fingers pan.
    ///   • fingerDraws == false → minimumNumberOfTouches = 1
    ///       Single finger scrolls. Pencil always draws (banned from this gesture).
    private func applyPanGestureConfig(_ scrollView: UIScrollView, fingerDraws: Bool) {
        scrollView.panGestureRecognizer.minimumNumberOfTouches = fingerDraws ? 2 : 1
    }

    private func applyTool(_ tool: InkTool, to canvasView: PKCanvasView) {
        switch tool {
        case .ruler:
            canvasView.isRulerActive = true
            // Keep the previous tool active alongside the ruler.
        default:
            canvasView.isRulerActive = false
            canvasView.tool = tool.makePKTool()
        }
    }
}

// MARK: - Coordinator

extension CanvasContainerView {

    final class Coordinator: NSObject,
        UIScrollViewDelegate,
        PKCanvasViewDelegate,
        UIPencilInteractionDelegate,
        UIGestureRecognizerDelegate {

        let viewModel: EditorViewModel

        weak var host:        UIView?
        weak var scrollView:  UIScrollView?
        weak var contentView: UIView?
        weak var renderer:    PageRenderer?
        weak var canvasView:  PKCanvasView?

        // Content overlays
        var mediaOverlayHosting: UIHostingController<MediaAttachmentOverlayView>?
        var textOverlayHosting:  UIHostingController<TextBlockOverlayView>?
        var audioOverlayHosting: UIHostingController<AudioAnnotationPinsOverlayView>?
        weak var audioContainer:    AudioPassthroughContainer?
        weak var gestureController: ContentLayerGestureController?

        var appliedTool:   InkTool?
        var appliedPageId: UUID?
        var suppressZoomUpdate: Bool = false

        // Two-finger swipe debounce — guard against double-firing during decel.
        private var lastSwipeDate: Date = .distantPast

        init(viewModel: EditorViewModel) {
            self.viewModel = viewModel
        }

        // MARK: - UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            contentView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(animated: false)
            if !suppressZoomUpdate {
                let z = scrollView.zoomScale
                if abs(viewModel.zoomScale - z) > 0.001 {
                    viewModel.zoomScale = z
                }
            }
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // The minimap reads scrollView contentOffset via a notification or
            // a published binding. For now we just keep ViewModel in sync via zoom.
            // (Stage 5 minimap drag will publish a NotificationCenter event.)
            NotificationCenter.default.post(
                name: .inkCanvasViewportDidChange,
                object: nil,
                userInfo: [
                    "offset": scrollView.contentOffset,
                    "size":   scrollView.bounds.size,
                    "zoom":   scrollView.zoomScale,
                ]
            )
        }

        /// Keep the page centred when smaller than the visible bounds.
        func centerContent(animated: Bool) {
            guard let scrollView, let contentView else { return }
            let scrolled = scrollView.bounds.size
            let zoomed   = CGSize(
                width:  contentView.frame.width,
                height: contentView.frame.height
            )
            let xPad = max(0, (scrolled.width  - zoomed.width)  / 2)
            let yPad = max(0, (scrolled.height - zoomed.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: yPad, left: xPad, bottom: yPad, right: xPad
            )
        }

        // MARK: - PKCanvasViewDelegate

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // Critical: do as little as possible here. Schedule the autosave and return.
            viewModel.scheduleAutosave()
        }

        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            // While drawing, keep the toolbar visible (don't auto-hide mid-stroke).
            viewModel.keepToolbarVisible()
            // Light tap on stroke begin (gated by `ink.haptics.drawing` setting).
            // prepare-ahead keeps the generator warm for the next stroke.
            HapticManager.shared.strokeBegins()
            HapticManager.shared.prepare(for: .strokeBegin)
        }

        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            // Resume the auto-hide timer once the user lifts the pencil.
            viewModel.resetToolbarTimer()
            // Kick the shape recognition pipeline (no-op if the user toggle
            // is off — handleStrokeEnded gates internally).
            viewModel.handleStrokeEnded()
        }

        // MARK: - UIPencilInteractionDelegate

        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            viewModel.handlePencilDoubleTap()
        }

        // MARK: - Gesture handlers

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView, let contentView else { return }
            // Fit to width, animated 0.3s ease-out (matches spec).
            let targetZoom = scrollView.bounds.width / contentView.bounds.width
            let clamped    = max(scrollView.minimumZoomScale,
                                 min(scrollView.maximumZoomScale, targetZoom))
            UIView.animate(
                withDuration: 0.3,
                delay: 0,
                options: [.curveEaseOut],
                animations: { scrollView.setZoomScale(clamped, animated: false) },
                completion: nil
            )
        }

        @objc func handleTwoFingerDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView else { return }
            UIView.animate(
                withDuration: 0.3, delay: 0, options: [.curveEaseOut],
                animations: { scrollView.setZoomScale(1.0, animated: false) },
                completion: nil
            )
        }

        @objc func handleSwipeLeft() {
            guard Date().timeIntervalSince(lastSwipeDate) > 0.4 else { return }
            lastSwipeDate = Date()
            viewModel.goToNextPage()
        }

        @objc func handleSwipeRight() {
            guard Date().timeIntervalSince(lastSwipeDate) > 0.4 else { return }
            lastSwipeDate = Date()
            viewModel.goToPreviousPage()
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let inkCanvasViewportDidChange = Notification.Name("ink.canvas.viewport.didChange")
}

// MARK: - UIView parent VC lookup

private extension UIView {
    func findParentViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let r = responder {
            if let vc = r as? UIViewController { return vc }
            responder = r.next
        }
        return nil
    }
}


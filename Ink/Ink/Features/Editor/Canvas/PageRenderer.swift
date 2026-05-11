import Combine
import PDFKit
import UIKit

/// Draws the page paper colour and casts the page-boundary shadow.
/// Template patterns (lined / grid / dot grid / cornell / etc.) are
/// painted by a SwiftUI `TemplatePatternView` mounted directly above
/// this view in the canvas hierarchy — see
/// `ContinuousCanvasView.mountCanvas(...)`. PageRenderer only owns the
/// background paint so the SwiftUI Canvas can stay theme-agnostic and
/// reuse the same code for thumbnails.
///
/// For PDF-backed pages (`pdfSourceURL` + `pdfPageIndex` set) the
/// renderer paints the source PDF page on top of the paper instead of
/// leaving the paper colour bare. The template overlay above the
/// renderer is hidden in that case — templates don't apply to PDF
/// backgrounds.
///
/// PageRenderer sits *behind* PKCanvasView inside the scroll view's
/// content view, so they zoom together. Its frame and the canvas
/// frame are kept in sync by the canvas container coordinator.
final class PageRenderer: UIView {

    // MARK: Configuration
    private(set) var pageSize: PageSize

    /// Pin the paper colour to its light-mode value regardless of the
    /// trait collection. Used by the customise panel's template
    /// thumbnails — they draw off-screen, so the view's
    /// `traitCollection` doesn't always rebuild from
    /// `overrideUserInterfaceStyle` and the dark-mode colour branch
    /// would paint a near-black thumb.
    var forceLightAppearance: Bool = false

    /// When set together, the renderer draws this page of the source
    /// PDF on top of the paper instead of leaving it blank. The PDF
    /// is read from disk on each `draw(_:)` — PDFKit caches the
    /// rendered tiles internally so subsequent redraws are cheap.
    private(set) var pdfSourceURL: URL?
    private(set) var pdfPageIndex: Int?
    /// Lazy PDFDocument — cached so we don't re-open the file on
    /// every redraw. Reset when the source URL changes.
    private var cachedPDFDocument: PDFDocument?

    /// Page id this renderer is attached to. Used to look up
    /// `PDFTextAnnotationStore` records on every draw so the
    /// highlight / underline / strikethrough overlay reflects the
    /// current store state. Optional so non-PDF / unattached
    /// renderers (template thumbnails in the customise panel) can
    /// skip the lookup entirely.
    private(set) var pageId: UUID?

    /// Observer token for `pdfTextAnnotationsChanged`. Soft-deleting
    /// a record posts that notification; the renderer reacts with
    /// `setNeedsDisplay` so overlays disappear without a page reload.
    private var annotationObserver: NSObjectProtocol?

    /// Combine subscription to the editor's `pulsingAnnotationId`.
    /// Set up by `attachPulseSource` and dropped on dealloc. Single
    /// subscriber per renderer instance; multiple renderers all
    /// observe the same publisher and only the one whose page
    /// currently holds the matching record reacts.
    private var pulseSubscription: AnyCancellable?

    // MARK: Init

    init(pageSize: PageSize) {
        self.pageSize  = pageSize
        super.init(frame: CGRect(origin: .zero, size: pageSize.pointSize))
        configureLayer()
        contentMode  = .redraw
        isOpaque     = true
        clearsContextBeforeDrawing = false
        backgroundColor = .clear   // we paint in draw(_:)

        // iOS 17+ replacement for `traitCollectionDidChange`. Re-paint
        // the page when the interface style flips so the paper colour
        // tracks light/dark. Captures `self` weakly — the registration
        // is held by UIKit for the view's lifetime.
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (view: PageRenderer, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        if let token = annotationObserver {
            NotificationCenter.default.removeObserver(token)
        }
        pulseSubscription?.cancel()
    }

    // MARK: Public mutators

    /// Update the renderer's paper size. The frame is *not* touched
    /// here — the host (the canvas coordinator) owns layout and will
    /// resize the view directly. This separation is what lets the
    /// editor's last page auto-grow vertically without `update`
    /// snapping the renderer back to a fixed pageSize.pointSize.
    func update(pageSize: PageSize) {
        self.pageSize = pageSize
        setNeedsDisplay()
    }

    /// Attach a source PDF page to this renderer. Pass `(nil, nil)` to
    /// switch back to the plain-paper rendering. Invalidates the
    /// cached `PDFDocument` if the source URL changed so on-disk
    /// edits to the PDF are picked up the next time the page renders.
    func updatePDFBacking(sourceURL: URL?, pageIndex: Int?) {
        let urlChanged = sourceURL != pdfSourceURL
        pdfSourceURL = sourceURL
        pdfPageIndex = pageIndex
        if urlChanged { cachedPDFDocument = nil }
        setNeedsDisplay()
    }

    /// Subscribe to the editor view-model's `pulsingAnnotationId`
    /// publisher. When the published id matches a record on this
    /// renderer's page, a yellow outline animates over the
    /// annotation's bounds for ~0.3s. Idempotent — calling twice
    /// replaces the previous subscription.
    ///
    /// Kept as a Combine subscription (not a notification) per the
    /// architecture rule: `pulsingAnnotationId` is the single
    /// signal for both the canvas overlay and the sticky-note
    /// overlay.
    func attachPulseSource<P: Publisher>(_ publisher: P)
        where P.Output == UUID?, P.Failure == Never
    {
        pulseSubscription?.cancel()
        pulseSubscription = publisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] id in
                guard let self, let id else { return }
                self.pulseIfRecordOnThisPage(id)
            }
    }

    /// Attach this renderer to a specific `Page.id` so the
    /// annotation overlay can look up records from
    /// `PDFTextAnnotationStore`. Wires the change-notification
    /// observer on first call so soft-deletes propagate without a
    /// page reload.
    func attachPageId(_ id: UUID?) {
        guard pageId != id else { return }
        pageId = id
        if annotationObserver == nil, id != nil {
            // Observer fires whenever the store mutates anywhere —
            // cheap, just calls `setNeedsDisplay` for this view.
            annotationObserver = NotificationCenter.default.addObserver(
                forName: .pdfTextAnnotationsChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.setNeedsDisplay()
            }
        }
        setNeedsDisplay()
    }

    // MARK: Layer / shadow

    private func configureLayer() {
        // Page-boundary shadow — second of only two shadows in the entire app.
        layer.shadowColor   = UIColor.black.cgColor
        layer.shadowOffset  = CGSize(width: 0, height: 1)
        layer.shadowRadius  = 4
        layer.shadowOpacity = 0.08
        layer.masksToBounds = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
    }

    // Trait-change handling moved to `registerForTraitChanges` in
    // `init` (iOS 17+ API). The `traitCollectionDidChange` override
    // is deprecated.

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let isDark = !forceLightAppearance
            && traitCollection.userInterfaceStyle == .dark
        let paper  = isDark ? UIColor(hex: "#1C1C1A") : UIColor(hex: "#FAFAF8")
        ctx.setFillColor(paper.cgColor)
        ctx.fill(self.bounds)

        // PDF page on top of the paper if this page is PDF-backed.
        if let pdfURL = pdfSourceURL,
           let pdfIndex = pdfPageIndex,
           let pdfPage = pdfPage(in: pdfURL, at: pdfIndex) {
            drawPDFPage(pdfPage, in: ctx, target: bounds)
        }

        // PDF text annotation overlay. Sits between the PDF
        // background (just drawn above) and the PencilKit canvas
        // (mounted as a separate view above this renderer in the
        // editor hierarchy), so the marks render visibly before the
        // debounced disk write-back fires and remain reactive to
        // soft-deletes from elsewhere in the app.
        if let pageId = pageId {
            drawTextAnnotationOverlay(pageId: pageId, in: ctx, target: bounds)
        }
    }

    private func pdfPage(in url: URL, at index: Int) -> PDFPage? {
        if cachedPDFDocument == nil {
            cachedPDFDocument = PDFDocument(url: url)
        }
        guard let doc = cachedPDFDocument, index < doc.pageCount else { return nil }
        return doc.page(at: index)
    }

    // MARK: - Pulse

    /// If `recordId` matches a record on this page, drop a
    /// `CAShapeLayer` at the record's overlay rect and animate
    /// scale 1.0 → 1.1 → 1.0 over 0.3s. The layer removes itself
    /// when the animation completes. Renderers on other pages no-op.
    private func pulseIfRecordOnThisPage(_ recordId: UUID) {
        guard let pageId,
              let record = PDFTextAnnotationStore.records(for: pageId)
                .first(where: { $0.id == recordId })
        else { return }

        let target = bounds
        let pdfPageBounds: CGRect
        if let pdfURL = pdfSourceURL,
           let pdfIndex = pdfPageIndex,
           let pdfPage = pdfPage(in: pdfURL, at: pdfIndex) {
            pdfPageBounds = pdfPage.bounds(for: .mediaBox)
        } else {
            pdfPageBounds = target
        }
        guard pdfPageBounds.width > 0, pdfPageBounds.height > 0 else { return }
        let scale = min(target.width / pdfPageBounds.width,
                        target.height / pdfPageBounds.height)
        let drawnWidth  = pdfPageBounds.width  * scale
        let drawnHeight = pdfPageBounds.height * scale
        let offsetX = (target.width  - drawnWidth)  / 2
        let offsetY = (target.height - drawnHeight) / 2

        let n = record.normalizedBounds
        let rect = CGRect(
            x: offsetX + n.minX * drawnWidth,
            y: offsetY + n.minY * drawnHeight,
            width:  n.width  * drawnWidth,
            height: n.height * drawnHeight
        )

        let pulse = CAShapeLayer()
        pulse.path = UIBezierPath(rect: rect).cgPath
        pulse.fillColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
        pulse.strokeColor = UIColor.systemYellow.cgColor
        pulse.lineWidth = 1.5
        pulse.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        // Translate so the scale animation rotates around the rect's
        // centre, not the layer's origin.
        pulse.position = CGPoint(x: rect.midX, y: rect.midY)
        pulse.bounds = CGRect(origin: .zero, size: rect.size)
        pulse.path = UIBezierPath(
            rect: CGRect(origin: CGPoint(x: -rect.width / 2, y: -rect.height / 2),
                         size: rect.size)
        ).cgPath
        layer.addSublayer(pulse)

        let scaleAnim = CAKeyframeAnimation(keyPath: "transform.scale")
        scaleAnim.values = [1.0, 1.1, 1.0]
        scaleAnim.keyTimes = [0.0, 0.5, 1.0]
        scaleAnim.duration = 0.30
        scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue   = 0.0
        opacityAnim.duration  = 0.30
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

        let group = CAAnimationGroup()
        group.animations = [scaleAnim, opacityAnim]
        group.duration = 0.30
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        pulse.add(group, forKey: "annotationPulse")
        // Remove the layer after the animation completes. Tracking
        // with a Task is cheaper than a CAAnimationDelegate for a
        // one-shot effect.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(320))
            pulse.removeFromSuperlayer()
        }
    }

    // MARK: - Text annotation overlay

    /// Paints highlight / underline / strikethrough rectangles read
    /// from `PDFTextAnnotationStore` over the PDF background.
    /// `normalizedBounds` is in 0–1 top-left-origin page coordinates;
    /// scale + offset are the same letterbox math `drawPDFPage` uses
    /// so the overlay lands exactly over the glyphs that produced it.
    private func drawTextAnnotationOverlay(pageId: UUID, in ctx: CGContext, target: CGRect) {
        let records = PDFTextAnnotationStore.records(for: pageId)
        guard !records.isEmpty else { return }

        // Same letterbox geometry as drawPDFPage. We compute against
        // the PDF page bounds when present; with no PDF (this
        // overlay only renders for PDF-backed pages where the
        // editor attached a pageId) we fall back to the renderer's
        // own bounds.
        let pdfPageBounds: CGRect
        if let pdfURL = pdfSourceURL,
           let pdfIndex = pdfPageIndex,
           let pdfPage = pdfPage(in: pdfURL, at: pdfIndex) {
            pdfPageBounds = pdfPage.bounds(for: .mediaBox)
        } else {
            pdfPageBounds = target
        }
        guard pdfPageBounds.width > 0, pdfPageBounds.height > 0 else { return }

        let scale = min(target.width / pdfPageBounds.width,
                        target.height / pdfPageBounds.height)
        let drawnWidth  = pdfPageBounds.width  * scale
        let drawnHeight = pdfPageBounds.height * scale
        let offsetX = (target.width  - drawnWidth)  / 2
        let offsetY = (target.height - drawnHeight) / 2

        for record in records {
            // Normalised bounds → canvas (target) coordinates.
            let n = record.normalizedBounds
            let rect = CGRect(
                x: offsetX + n.minX * drawnWidth,
                y: offsetY + n.minY * drawnHeight,
                width:  n.width  * drawnWidth,
                height: n.height * drawnHeight
            )

            switch record.type {
            case .highlight:
                // Translucent yellow fill — same value as the spec.
                ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(0.35).cgColor)
                ctx.fill(rect)
            case .underline:
                // 1.5pt line along the bottom edge.
                ctx.setStrokeColor(UIColor.systemYellow.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: rect.minX, y: rect.maxY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                ctx.strokePath()
            case .strikethrough:
                // 1.5pt line at the vertical midpoint.
                let midY = rect.midY
                ctx.setStrokeColor(UIColor.systemYellow.cgColor)
                ctx.setLineWidth(1.5)
                ctx.move(to: CGPoint(x: rect.minX, y: midY))
                ctx.addLine(to: CGPoint(x: rect.maxX, y: midY))
                ctx.strokePath()
            }
        }
    }

    private func drawPDFPage(_ page: PDFPage, in ctx: CGContext, target: CGRect) {
        let pageBounds = page.bounds(for: .mediaBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else { return }

        // Fit the PDF page inside our bounds preserving aspect ratio,
        // centred. Notebook canvas size may not match PDF native size
        // (especially after blank pages are added at notebook
        // defaults), so we letterbox rather than stretching.
        let scale = min(
            target.width  / pageBounds.width,
            target.height / pageBounds.height
        )
        let drawnWidth  = pageBounds.width  * scale
        let drawnHeight = pageBounds.height * scale
        let offsetX = (target.width  - drawnWidth)  / 2
        let offsetY = (target.height - drawnHeight) / 2

        ctx.saveGState()
        ctx.translateBy(x: offsetX, y: offsetY)
        ctx.scaleBy(x: scale, y: scale)
        // PDF coordinate space is y-up; UIKit's is y-down. Flip.
        ctx.translateBy(x: 0, y: pageBounds.height)
        ctx.scaleBy(x: 1, y: -1)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
    }
}

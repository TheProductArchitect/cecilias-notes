import UIKit

/// Draws the page paper colour and casts the page-boundary shadow.
/// Template patterns (lined / grid / dot grid / cornell / etc.) are
/// painted by a SwiftUI `TemplatePatternView` mounted directly above
/// this view in the canvas hierarchy — see
/// `ContinuousCanvasView.mountCanvas(...)`. PageRenderer only owns the
/// background paint so the SwiftUI Canvas can stay theme-agnostic and
/// reuse the same code for thumbnails.
///
/// Step 5.5: stripped of every PDF / highlight code path. PDF page
/// content renders via `PDFPageElementsOverlayView` (Step 4.5) and
/// highlights via `HighlightElementsOverlayView` (Step 5.5); both
/// mount as separate hosts inside the same renderer's subview
/// hierarchy. The legacy `pdfSourceURL` / `pdfPageIndex` /
/// `PDFTextAnnotationStore` / pulse-subscription scaffolding all
/// went away in one pass.
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
        // tracks light/dark.
        registerForTraitChanges(
            [UITraitUserInterfaceStyle.self]
        ) { (view: PageRenderer, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

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

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let isDark = !forceLightAppearance
            && traitCollection.userInterfaceStyle == .dark
        let paper  = isDark ? UIColor(hex: "#1C1C1A") : UIColor(hex: "#FAFAF8")
        ctx.setFillColor(paper.cgColor)
        ctx.fill(self.bounds)
    }

    // MARK: - Diagnostic — OPEN_ISSUES #1 (element-tap gesture absorption)

    #if DEBUG
    /// Observe-only `hitTest` instrumentation. The `[TouchPath]`
    /// logger localised the touch death to this layer — the sequence
    /// reaches "4. page renderer" and stops; label 5 (PKCanvasView)
    /// and label 6 (image/sticky/audio overlay hosts) never fire.
    ///
    /// For every touch-type hit test over the page this logs:
    ///   • the point received,
    ///   • the view `super.hitTest` actually resolves to,
    ///   • this renderer's superview, and
    ///   • each immediate subview in z-order (back-to-front) with its
    ///     type, frame, `isUserInteractionEnabled`, `isHidden`, alpha
    ///     — the four properties that decide whether `hitTest`
    ///     descends into a subview.
    ///
    /// Pure observation: returns `super`'s result unchanged, exactly
    /// like `TouchPathLogger`. Remove once #1 is resolved.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let result = super.hitTest(point, with: event)
        if event?.type == .touches, bounds.contains(point) {
            let resultType = result.map { String(describing: type(of: $0)) } ?? "nil"
            let superType  = superview.map { String(describing: type(of: $0)) } ?? "nil"
            print("[Renderer-hit] point=\(point) rendererFrame=\(frame) "
                + "super.hitTest=\(resultType) superview=\(superType)")
            if subviews.isEmpty {
                print("[Renderer-hit]   subviews: none — overlay hosts are NOT children of this renderer")
            } else {
                for (i, sub) in subviews.enumerated() {
                    print("[Renderer-hit]   subview[\(i)] \(type(of: sub)) "
                        + "frame=\(sub.frame) userInteraction=\(sub.isUserInteractionEnabled) "
                        + "hidden=\(sub.isHidden) alpha=\(sub.alpha)")
                }
            }
        }
        return result
    }
    #endif
}

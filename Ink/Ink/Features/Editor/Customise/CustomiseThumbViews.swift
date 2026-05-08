import SwiftUI

// MARK: - CoverThumbView

/// Live thumbnail of a `NotebookCover` — paints colour + texture using
/// the same `CoverTextureCanvas` the library cards already use, so the
/// thumbnail matches what the user will see on the card.
struct CoverThumbView: View {
    let cover: NotebookCover
    let size: CGSize

    var body: some View {
        ZStack {
            Color(UIColor(hex: cover.colorHex))
            CoverTextureCanvas(texture: cover.texture)
                .opacity(0.85)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            // Subtle inner edge so very pale covers (cream, parchment)
            // remain distinguishable on the elevated panel background.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
        )
    }
}

// MARK: - TemplateThumbView

/// Small live preview of a `PageTemplate`, rendered by wrapping the
/// existing `PageRenderer` (UIKit) in a `UIViewRepresentable`. We render
/// at a small fixed `PageSize` and let SwiftUI scale the view down via
/// the frame modifier — PageRenderer's own draw routines are
/// resolution-independent so this looks crisp at thumb size.
struct TemplateThumbView: View {
    let template: PageTemplate
    let size: CGSize

    var body: some View {
        TemplateThumbHost(template: template)
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct TemplateThumbHost: UIViewRepresentable {
    let template: PageTemplate

    func makeUIView(context: Context) -> ScaledPageRendererView {
        ScaledPageRendererView(template: template)
    }

    func updateUIView(_ view: ScaledPageRendererView, context: Context) {
        view.update(template: template)
    }
}

/// Hosts a `PageRenderer` at A4 native size and scales it down to fit.
/// This keeps the Core Graphics drawing crisp — we paint once at full
/// page-point resolution then transform the layer.
private final class ScaledPageRendererView: UIView {
    private let renderer: PageRenderer

    init(template: PageTemplate) {
        self.renderer = PageRenderer(pageSize: .a4, template: template)
        super.init(frame: .zero)
        addSubview(renderer)
        clipsToBounds = true
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func update(template: PageTemplate) {
        renderer.update(pageSize: .a4, template: template)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let pageSize = PageSize.a4.pointSize
        let scale = min(bounds.width / pageSize.width, bounds.height / pageSize.height)
        renderer.transform = .identity
        renderer.bounds = CGRect(origin: .zero, size: pageSize)
        renderer.center = CGPoint(x: bounds.midX, y: bounds.midY)
        renderer.transform = CGAffineTransform(scaleX: scale, y: scale)
    }
}

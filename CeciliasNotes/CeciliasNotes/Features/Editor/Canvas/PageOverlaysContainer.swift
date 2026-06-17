import SwiftUI

/// Single SwiftUI host for every interactive per-page overlay.
///
/// **OPEN_ISSUES #1 — element-tap gesture absorption.** Each overlay
/// used to be mounted in its own `UIHostingController` and stacked
/// inside the page's `PageRenderer`. The `[Renderer-hit]`
/// per-subview probe proved that a `_UIHostingView` claims its
/// entire frame for hit-testing whenever `isUserInteractionEnabled`
/// is true — an empty overlay with zero elements and no tap-catcher
/// still returned *itself* from `hitTest`. With eight stacked hosts
/// the topmost interaction-enabled one (`TextElementsOverlayView`)
/// absorbed every tap before UIKit's walk could reach the overlays
/// below it. No SwiftUI-level gating could fix that: the absorption
/// happened at the UIKit host boundary, before SwiftUI was ever
/// consulted.
///
/// Hosting every overlay inside ONE view collapses the problem.
/// There is a single `_UIHostingView`; hit routing happens *inside*
/// one SwiftUI tree, where SwiftUI correctly delivers each tap to
/// the element — or background tap-catcher — actually at that point.
/// The container view itself is still "greedy" toward `PageRenderer`
/// (it claims the page), but that is correct: everything that should
/// receive a page tap now lives inside it, and a tap that lands on
/// nothing is simply consumed with no effect.
///
/// Layering is a fixed back-to-front `ZStack` order. The per-tool
/// `bringSubviewToFront` promotion (`promoteActiveOverlayToFront`)
/// that used to paper over the cross-host absorption is gone — with
/// one tree, SwiftUI routes a tap to whichever element is genuinely
/// at the point regardless of overlay order, so a stable order is
/// all that is needed.
///
/// `TemplatePatternView` is deliberately NOT here: it is
/// non-interactive and needs its own `rootView` swap when the
/// Customise panel changes a page's template, so it stays a
/// separate host mounted behind this container inside the renderer.
struct PageOverlaysContainer: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let notebookId: UUID
    let coordinateSpace: PageCoordinateSpace

    var body: some View {
        // Back-to-front. Mirrors the legacy cursor-mode stacking the
        // old `promoteActiveOverlayToFront` produced: the stroke
        // seed and legacy TextBlock layer at the back, media in the
        // middle, V6 text elements above them, lasso on top so its
        // selection chrome and capture surface win over element
        // gestures.
        ZStack(alignment: .topLeading) {
            StrokeElementsOverlayView(
                pageId: pageId,
                notebookId: notebookId,
                coordinateSpace: coordinateSpace
            )

            TextBlockOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                coordinateSpace: coordinateSpace
            )

            ImageElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                notebookId: notebookId,
                coordinateSpace: coordinateSpace
            )

            PDFPageElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                coordinateSpace: coordinateSpace
            )

            HighlightElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                coordinateSpace: coordinateSpace
            )

            AudioElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                coordinateSpace: coordinateSpace
            )

            StickyNoteElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                notebookId: notebookId,
                coordinateSpace: coordinateSpace
            )

            TextElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                notebookId: notebookId,
                coordinateSpace: coordinateSpace
            )

            // Shape overlay sits above text so the shape-tool
            // drag-capture surface gets priority while it's the
            // active tool. When the shape tool is off the overlay
            // only renders existing shapes and forwards taps down.
            ShapeElementsOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                notebookId: notebookId,
                coordinateSpace: coordinateSpace
            )

            LassoOverlayView(
                viewModel: viewModel,
                pageId: pageId,
                coordinateSpace: coordinateSpace
            )
        }
        .frame(
            width: coordinateSpace.baseSize.width,
            height: coordinateSpace.baseSize.height,
            alignment: .topLeading
        )
    }
}

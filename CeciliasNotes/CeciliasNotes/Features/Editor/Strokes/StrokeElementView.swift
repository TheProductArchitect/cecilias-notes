import SwiftData
import SwiftUI

/// Renders one V6 `PageElement` of kind `.stroke`. Step 8 — the
/// per-element view in the unified template. **Visually
/// transparent.** PKCanvasView (mounted by
/// `ContinuousCanvasView.mountCanvas`) does the actual stroke
/// rendering; this view exists only so the stroke primitive
/// participates in the same SwiftData-binding + per-page overlay
/// pattern as text / image / sticky / audio / highlight.
///
/// **Step 9 hook.** When lasso lands, this view is where per-
/// element selection chrome (lasso outline + scale/rotate handles)
/// will hang. For Step 8 the body is just `Color.clear` with
/// hit-testing disabled — the canvas owns every touch in the
/// stroke layer.
struct StrokeElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: StrokeContent
    let pageSize: CGSize
    @Binding var isSelected: Bool

    var body: some View {
        Color.clear
            .frame(width: pageSize.width, height: pageSize.height)
            .allowsHitTesting(false)
    }
}

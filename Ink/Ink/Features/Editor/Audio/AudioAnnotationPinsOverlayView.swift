import SwiftUI

// MARK: - AudioAnnotationPinsOverlayView

/// SwiftUI overlay that renders all audio annotation pins for a
/// specific page. Always interactive regardless of selected tool
/// (audio pins are never blocked by the gesture controller).
///
/// Mounted per-page inside each `PageRenderer` — the overlay
/// inherits the page's coordinate space automatically, so pins
/// stay anchored to their page through any amount of scroll.
struct AudioAnnotationPinsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    /// Page this overlay belongs to. When set, only annotations
    /// owned by this page are rendered. When `nil` the overlay
    /// falls back to the currently-active page's annotations
    /// (legacy single-overlay behaviour for any caller that
    /// hasn't migrated yet).
    var pageId: UUID? = nil

    @State private var draggingAnnotation:  AudioAnnotation?
    @State private var dragOffset:          CGSize = .zero

    /// Annotations to render — page-scoped when `pageId` is
    /// supplied, otherwise the current-page list from the view
    /// model. Audio annotations live in SwiftData on `Page`, so we
    /// resolve through `viewModel.pages` rather than reaching into
    /// the storage layer directly.
    private var annotations: [AudioAnnotation] {
        if let pageId,
           let page = viewModel.pages.first(where: { $0.id == pageId }) {
            return (page.audioAnnotations ?? [])
                .filter { !$0.isDeleted }
                .sorted { $0.recordedAt < $1.recordedAt }
        }
        return viewModel.currentPageAudioAnnotations
    }

    var body: some View {
        // Sizes itself from the parent UIView's bounds. Per-page
        // mounting means the parent is the page's `PageRenderer`,
        // whose bounds is the page point-size — pin positions land
        // in page-local coordinates without any scroll-offset math.
        GeometryReader { proxy in
            let pageSize = proxy.size
            ZStack(alignment: .topLeading) {
                ForEach(annotations) { annotation in
                    pinView(for: annotation, pageSize: pageSize)
                }
            }
            .frame(width: pageSize.width, height: pageSize.height)
        }
    }

    // MARK: - Per-pin view

    @ViewBuilder
    private func pinView(for annotation: AudioAnnotation, pageSize: CGSize) -> some View {
        let baseX = annotation.pageX * Double(pageSize.width)
        let baseY = annotation.pageY * Double(pageSize.height)
        let dx    = draggingAnnotation?.id == annotation.id ? dragOffset.width  : 0
        let dy    = draggingAnnotation?.id == annotation.id ? dragOffset.height : 0

        AudioAnnotationPinView(
            annotation:  annotation,
            isPlaying:   viewModel.playingAnnotationId == annotation.id,
            onLongPress: {
                draggingAnnotation = annotation
            },
            viewModel:   viewModel
        )
        .position(x: CGFloat(baseX) + dx, y: CGFloat(baseY) + dy)
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    draggingAnnotation = annotation
                    dragOffset = value.translation
                }
                .onEnded { value in
                    let newX = min(max(0, (CGFloat(baseX) + value.translation.width)  / pageSize.width),  1)
                    let newY = min(max(0, (CGFloat(baseY) + value.translation.height) / pageSize.height), 1)
                    viewModel.moveAudioAnnotation(annotation, to: CGPoint(x: newX, y: newY))
                    draggingAnnotation = nil
                    dragOffset = .zero
                }
        )
        .contextMenu {
            Button(role: .destructive) {
                viewModel.deleteAudioAnnotation(annotation)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

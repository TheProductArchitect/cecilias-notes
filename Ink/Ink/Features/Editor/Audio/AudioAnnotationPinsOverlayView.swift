import SwiftUI

// MARK: - AudioAnnotationPinsOverlayView

/// SwiftUI overlay that renders all audio annotation pins for the current page.
/// Always interactive regardless of selected tool (audio pins are never blocked by gesture controller).
struct AudioAnnotationPinsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel

    /// Page size in points — used to convert normalised pin positions.
    /// Updated by CanvasContainerView.updateUIView when page changes.
    var pageSize: CGSize

    @State private var draggingAnnotation:  AudioAnnotation?
    @State private var dragOffset:          CGSize = .zero

    var body: some View {
        // Each pin owns its own .popover anchored to its centre — there is no
        // parent-level sheet/popover here.
        ZStack(alignment: .topLeading) {
            ForEach(viewModel.currentPageAudioAnnotations) { annotation in
                pinView(for: annotation)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
    }

    // MARK: - Per-pin view

    @ViewBuilder
    private func pinView(for annotation: AudioAnnotation) -> some View {
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

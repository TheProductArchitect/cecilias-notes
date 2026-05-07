import SwiftUI

// MARK: - AudioAnnotationPinsOverlayView

/// SwiftUI overlay that renders all audio annotation pins for the current page.
/// Always interactive regardless of selected tool (audio pins are never blocked by gesture controller).
struct AudioAnnotationPinsOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel

    /// Page size in points — used to convert normalised pin positions.
    /// Updated by CanvasContainerView.updateUIView when page changes.
    var pageSize: CGSize

    @State private var playerAnnotation:    AudioAnnotation?
    @State private var draggingAnnotation:  AudioAnnotation?
    @State private var dragOffset:          CGSize = .zero

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(Rectangle())

            ForEach(viewModel.currentPageAudioAnnotations) { annotation in
                pinView(for: annotation)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height)
        .sheet(item: $playerAnnotation) { ann in
            AudioPlayerView(annotation: ann, viewModel: viewModel)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
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
            onTap: {
                playerAnnotation = annotation
            },
            onLongPress: {
                draggingAnnotation = annotation
            }
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
                    try? StorageService.shared.moveAudioAnnotation(annotation, to: CGPoint(x: newX, y: newY))
                    viewModel.refreshCurrentPageAudioAnnotations()
                    draggingAnnotation = nil
                    dragOffset = .zero
                }
        )
        .contextMenu {
            Button(role: .destructive) {
                try? StorageService.shared.deleteAudioAnnotation(annotation)
                viewModel.refreshCurrentPageAudioAnnotations()
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

// MARK: - AudioAnnotation: Identifiable

extension AudioAnnotation: Identifiable {}

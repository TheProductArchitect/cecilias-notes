import SwiftUI

// MARK: - ResizeHandlesView

/// Draws 8 resize handles around a selected text block.
/// The parent passes the block's frame in page-point coordinates.
/// Drag deltas are reported as normalised-rect mutations via onResize.
struct ResizeHandlesView: View {

    let pageSize: CGSize
    let pointRect: CGRect                             // current block rect in page points
    let onResize: (ResizeHandle, CGPoint) -> Void     // (handle, translation in page points)
    let onResizeEnded: () -> Void

    private let handleSize: CGFloat = 10
    private let hitPad:     CGFloat = 12

    var body: some View {
        ZStack {
            // Selection border (1pt accent)
            Rectangle()
                .strokeBorder(Color.inkAccentPrimary, lineWidth: 1)
                .frame(width: pointRect.width, height: pointRect.height)
                .position(x: pointRect.midX, y: pointRect.midY)

            // Handles
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                handleView(for: handle)
            }
        }
    }

    @ViewBuilder
    private func handleView(for handle: ResizeHandle) -> some View {
        let pos = handlePosition(for: handle)

        Circle()
            .fill(Color.inkBackgroundElevated)
            .overlay(Circle().strokeBorder(Color.inkAccentPrimary, lineWidth: 1.5))
            .frame(width: handleSize, height: handleSize)
            .position(pos)
            .contentShape(Circle().size(width: hitPad * 2, height: hitPad * 2))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        onResize(handle, CGPoint(x: value.translation.width,
                                                 y: value.translation.height))
                    }
                    .onEnded { _ in onResizeEnded() }
            )
    }

    private func handlePosition(for handle: ResizeHandle) -> CGPoint {
        let anchor = handle.anchor
        return CGPoint(
            x: pointRect.origin.x + anchor.x * pointRect.width,
            y: pointRect.origin.y + anchor.y * pointRect.height
        )
    }
}

// MARK: - ResizeHandle Identifiable

extension ResizeHandle: Identifiable {
    var id: String { "\(self)" }
}

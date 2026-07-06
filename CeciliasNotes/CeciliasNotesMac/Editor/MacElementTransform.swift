import SwiftData
import SwiftUI

/// Drag + corner-resize for selected Mac page elements.
struct MacElementTransformModifier: ViewModifier {
    @Bindable var element: PageElement
    let pageSize: CGSize
    let isSelected: Bool
    let context: ModelContext

    @State private var dragOrigin: CGPoint?
    @State private var resizeOrigin: (width: Double, height: Double, x: Double, y: Double)?
    @State private var rotateOrigin: Double?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if showsResizeHandle {
                    resizeHandle
                }
            }
            .overlay(alignment: .top) {
                if showsRotateHandle {
                    rotateHandle
                }
            }
            .highPriorityGesture(showsMoveGesture ? moveGesture : nil)
    }

    private var showsResizeHandle: Bool {
        isSelected && element.kind != .audio && element.kind != .text
    }

    private var showsRotateHandle: Bool {
        isSelected && element.kind != .audio && element.kind != .text
    }

    private var showsMoveGesture: Bool {
        isSelected && element.kind != .audio
    }

    private var textVerticalOnly: Bool {
        element.kind == .text
    }

    private var resizeHandle: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 10, height: 10)
            .offset(x: 6, y: 6)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if resizeOrigin == nil {
                            resizeOrigin = (
                                element.normalizedWidth,
                                element.normalizedHeight,
                                element.normalizedX,
                                element.normalizedY
                            )
                        }
                        guard let origin = resizeOrigin else { return }
                        let dw = Double(value.translation.width / pageSize.width)
                        let dh = Double(value.translation.height / pageSize.height)
                        element.normalizedWidth = max(0.05, min(1 - origin.x, origin.width + dw))
                        element.normalizedHeight = max(0.04, min(1 - origin.y, origin.height + dh))
                    }
                    .onEnded { _ in
                        resizeOrigin = nil
                        commit()
                    }
            )
            .accessibilityLabel("Resize")
    }

    private var rotateHandle: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(4)
            .background(Circle().fill(Color(nsColor: .controlBackgroundColor)))
            .offset(y: -14)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        if rotateOrigin == nil { rotateOrigin = element.rotation }
                        guard let origin = rotateOrigin else { return }
                        let delta = Double(value.translation.width / max(1, pageSize.width)) * .pi * 2
                        element.rotation = origin + delta
                    }
                    .onEnded { _ in
                        rotateOrigin = nil
                        commit()
                    }
            )
            .accessibilityLabel("Rotate")
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if dragOrigin == nil {
                    dragOrigin = CGPoint(x: element.normalizedX, y: element.normalizedY)
                }
                guard let origin = dragOrigin else { return }
                let dy = Double(value.translation.height / pageSize.height)
                if textVerticalOnly {
                    element.normalizedY = max(0, min(1 - element.normalizedHeight, origin.y + dy))
                } else {
                    let dx = Double(value.translation.width / pageSize.width)
                    element.normalizedX = max(0, min(1 - element.normalizedWidth, origin.x + dx))
                    element.normalizedY = max(0, min(1 - element.normalizedHeight, origin.y + dy))
                }
            }
            .onEnded { _ in
                dragOrigin = nil
                commit()
            }
    }

    private func commit() {
        element.updatedAt = Date()
        try? context.save()
    }
}

extension View {
    func macElementTransform(
        element: PageElement,
        pageSize: CGSize,
        isSelected: Bool,
        context: ModelContext
    ) -> some View {
        modifier(MacElementTransformModifier(
            element: element,
            pageSize: pageSize,
            isSelected: isSelected,
            context: context
        ))
    }
}

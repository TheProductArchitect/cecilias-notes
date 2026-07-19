import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement` of kind `.pdfPage` inside its
/// normalised page bounds. Third PageElement-backed view
/// (after `TextElementView` Step 3 and `ImageElementView` Step 4);
/// follows the same template.
///
/// Selection chrome mirrors the image element's treatment so users
/// perceive a consistent visual language across primitives:
///   • Dashed accent border (1.5pt, dash [4, 3]).
///   • Four corner accent-circle handles (10pt, -8pt hit expand)
///     drive aspect-locked resize.
///   • Floating toolbar above the page: drag-handle (move),
///     rotate-90°, delete.
///   • Pinch-to-resize + drag-to-move on the page body when
///     selected.
struct PDFPageElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: PDFPageContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    let onDelete: () -> Void

    @Environment(\.theme) private var theme
    @ObservedObject private var modifierKeys = ModifierKeyObserver.shared

    @State private var dragOffset: CGSize = .zero
    @State private var pinchScale: CGFloat = 1.0
    @State private var resizeDelta: ResizeDelta? = nil

    private static let handleSize: CGFloat = 10
    private static let toolbarGap: CGFloat = 8
    private static let minNormalizedWidth: Double = 0.05

    private struct ResizeDelta: Equatable {
        var corner: Corner
        var translation: CGSize
    }
    private enum Corner: Equatable { case topLeft, topRight, bottomLeft, bottomRight }

    var body: some View {
        let base = CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: element.normalizedWidth * pageSize.width,
            height: element.normalizedHeight * pageSize.height
        )
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // Gestures BEFORE `.position(...)` per the Step 7.2
            // canonical pattern — see `ImageElementView.body` for
            // the post-mortem on why post-position gestures fail
            // to fire on iPad OS 26.
            PDFPageDataView(content: content)
                .rotationEffect(.radians(element.rotation))
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        // Toggle — full-page PDF references cover the
                        // whole canvas, so blank-tap deselect never
                        // has an empty target outside the element.
                        isSelected.toggle()
                    }
                )
                .gesture(isSelected ? pageDragGesture : nil)
                .gesture(isSelected ? pinchResizeGesture : nil)
                .position(x: displayed.midX, y: displayed.midY)

            if isSelected {
                selectionChrome(rect: displayed)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
    }

    // MARK: - Displayed rect

    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation,
                               freeAxis: modifierKeys.isShiftHeld)
        }
        let scale = pinchScale
        let w = base.width  * scale
        let h = base.height * scale
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func resizedRect(
        base: CGRect,
        corner: Corner,
        translation: CGSize,
        freeAxis: Bool = false
    ) -> CGRect {
        let anchor: CGPoint
        let signX: CGFloat
        let signY: CGFloat
        switch corner {
        case .topLeft:     anchor = CGPoint(x: base.maxX, y: base.maxY); signX = -1; signY = -1
        case .topRight:    anchor = CGPoint(x: base.minX, y: base.maxY); signX =  1; signY = -1
        case .bottomLeft:  anchor = CGPoint(x: base.maxX, y: base.minY); signX = -1; signY =  1
        case .bottomRight: anchor = CGPoint(x: base.minX, y: base.minY); signX =  1; signY =  1
        }
        let minW = CGFloat(Self.minNormalizedWidth) * pageSize.width
        if freeAxis {
            let finalW = max(minW, base.width  + signX * translation.width)
            let finalH = max(minW, base.height + signY * translation.height)
            let x = anchor.x - (signX > 0 ? 0 : finalW)
            let y = anchor.y - (signY > 0 ? 0 : finalH)
            return CGRect(x: x, y: y, width: finalW, height: finalH)
        }
        let proposedW = max(1, base.width  + signX * translation.width)
        let proposedH = max(1, base.height + signY * translation.height)
        let scale  = max(proposedW / base.width, proposedH / base.height)
        let finalW = max(minW, base.width * scale)
        let finalH = base.height * (finalW / base.width)
        let x = anchor.x - (signX > 0 ? 0 : finalW)
        let y = anchor.y - (signY > 0 ? 0 : finalH)
        return CGRect(x: x, y: y, width: finalW, height: finalH)
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private func selectionChrome(rect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(
                theme.accent,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: rect.width, height: rect.height)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)

        cornerHandle(.topLeft,     at: CGPoint(x: rect.minX, y: rect.minY))
        cornerHandle(.topRight,    at: CGPoint(x: rect.maxX, y: rect.minY))
        cornerHandle(.bottomLeft,  at: CGPoint(x: rect.minX, y: rect.maxY))
        cornerHandle(.bottomRight, at: CGPoint(x: rect.maxX, y: rect.maxY))

        floatingToolbar()
            .position(
                x: rect.midX,
                y: max(14, rect.minY - Self.toolbarGap - 14)
            )
    }

    private func cornerHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(theme.accent)
            .frame(width: Self.handleSize, height: Self.handleSize)
            .contentShape(Rectangle().inset(by: -8))
            .position(point)
            .gesture(resizeGesture(for: corner))
    }

    private func floatingToolbar() -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(theme.foreground)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
                .gesture(pageDragGesture)

            Button {
                rotate90()
            } label: {
                Image(systemName: "rotate.right")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.foreground)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.borderSubtle, lineWidth: 0.5)
        )
    }

    // MARK: - Gestures

    private var pageDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                element.normalizedX = clampNorm(element.normalizedX + Double(dxNorm))
                element.normalizedY = clampNorm(element.normalizedY + Double(dyNorm))
                element.updatedAt   = Date()
                dragOffset = .zero
            }
    }

    private var pinchResizeGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                pinchScale = max(0.2, min(5, value))
            }
            .onEnded { value in
                let clamped = max(0.2, min(5, value))
                let newW = max(Self.minNormalizedWidth, element.normalizedWidth * Double(clamped))
                let newH = element.normalizedHeight * (newW / element.normalizedWidth)
                element.normalizedWidth  = min(1, newW)
                element.normalizedHeight = min(1, newH)
                element.updatedAt        = Date()
                pinchScale = 1.0
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                let base = CGRect(
                    x: element.normalizedX * pageSize.width,
                    y: element.normalizedY * pageSize.height,
                    width: element.normalizedWidth * pageSize.width,
                    height: element.normalizedHeight * pageSize.height
                )
                let new = resizedRect(base: base, corner: corner, translation: value.translation,
                                      freeAxis: modifierKeys.isShiftHeld)
                element.normalizedX      = clampNorm(Double(new.minX) / Double(pageSize.width))
                element.normalizedY      = clampNorm(Double(new.minY) / Double(pageSize.height))
                element.normalizedWidth  = min(1, Double(new.width)  / Double(pageSize.width))
                element.normalizedHeight = min(1, Double(new.height) / Double(pageSize.height))
                element.updatedAt        = Date()
                resizeDelta = nil
            }
    }

    private func rotate90() {
        let next = element.rotation + .pi / 2
        let twoPi = 2 * Double.pi
        element.rotation = next.truncatingRemainder(dividingBy: twoPi)
        element.updatedAt = Date()
    }

    private func clampNorm(_ v: Double) -> Double { max(0, min(1, v)) }
}

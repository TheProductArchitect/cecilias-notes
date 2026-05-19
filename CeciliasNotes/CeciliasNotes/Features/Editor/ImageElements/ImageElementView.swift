import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement` of kind `.image` inside its
/// normalised page bounds. Second PageElement-backed view (after
/// `TextElementView`); follows the same template — element +
/// bindable content + page-size projection + selection chrome
/// composited over the renderable.
///
/// Selection chrome (mirrors the visual treatment of the legacy
/// `ImageAttachmentSlot` so the user perceives no regression):
///   • Dashed accent border (1.5pt, dash [4, 3]).
///   • Four corner handles (10pt accent circles, hit-expanded
///     -8pt) drive aspect-locked resize via opposite-corner
///     anchoring.
///   • Floating toolbar above the image: drag-handle (move),
///     90° rotate, delete.
///   • Pinch-to-resize on the image body (aspect-locked, around
///     centre).
///   • Drag on the image body to move (when selected).
struct ImageElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: ImageContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    /// Invoked when the user taps the floating toolbar's trash icon.
    /// The overlay clears `selectedId` and soft-deletes via
    /// `element.deletedAt = Date()` — letting the parent own the
    /// fetch refresh keeps SwiftData mutations in one place.
    let onDelete: () -> Void

    @Environment(\.theme) private var theme

    // Transient gesture deltas — kept local so a drag/resize tick
    // doesn't write to SwiftData every frame; commits land on
    // `.onEnded`.
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
        let _ = print("[GestureAudit] ImageElementView body render — elementId=\(element.id.uuidString.prefix(8)) isSelected=\(isSelected) displayed=\(displayed) pageSize=\(pageSize)")

        ZStack(alignment: .topLeading) {
            // Order is load-bearing — gestures MUST sit before
            // `.position(...)`. After Step 7.2's sticky-gesture
            // post-mortem: `.position` wraps the modified view in
            // a parent-sized container; any gesture attached
            // after `.position` ends up bound to that container
            // instead of the framed contentShape, which on iPad
            // OS 26 causes the gesture to never fire even when
            // the hit area is correct. Apply the canonical
            // template established by `StickyNoteElementView`:
            //   frame → overlays/effects → contentShape →
            //   gestures → position.
            ImageDataView(content: content)
                .rotationEffect(.radians(element.rotation))
                .frame(width: displayed.width, height: displayed.height)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        print("[ImageGesture] 1. tap received on image body, elementId=\(element.id.uuidString.prefix(8)), isSelected before=\(isSelected)")
                        if !isSelected { isSelected = true }
                        print("[ImageGesture] 1a. tap handler done, isSelected after=\(isSelected)")
                    }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                        print("[ImageGesture] 1b. long-press received on image body, elementId=\(element.id.uuidString.prefix(8)), isSelected=\(isSelected)")
                    }
                )
                .gesture(isSelected ? imageDragGesture : nil)
                .gesture(isSelected ? pinchResizeGesture : nil)
                .position(x: displayed.midX, y: displayed.midY)

            if isSelected {
                selectionChrome(imageRect: displayed)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onChange(of: isSelected) { oldValue, newValue in
            print("[ImageGesture] isSelected changed elementId=\(element.id.uuidString.prefix(8)) old=\(oldValue) new=\(newValue)")
        }
    }

    // MARK: - Displayed rect (gesture-deltas applied to base)

    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation)
        }
        let scale = pinchScale
        let w = base.width  * scale
        let h = base.height * scale
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    /// Aspect-locked corner resize. The opposite corner stays
    /// pinned in space; the dragged corner moves by the drag
    /// translation; size scales uniformly along the controlling
    /// diagonal.
    private func resizedRect(
        base: CGRect,
        corner: Corner,
        translation: CGSize
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
        let proposedW = max(1, base.width  + signX * translation.width)
        let proposedH = max(1, base.height + signY * translation.height)
        let scaleW = proposedW / base.width
        let scaleH = proposedH / base.height
        let scale  = max(scaleW, scaleH)
        let w = base.width  * scale
        // `h` was computed for symmetry but never used — the aspect-
        // locked path derives the final height from the final width
        // below. Drop the binding to silence the unused-variable
        // warning.
        let minW = CGFloat(Self.minNormalizedWidth) * pageSize.width
        let finalW = max(minW, w)
        let finalH = base.height * (finalW / base.width)
        let x = anchor.x - (signX > 0 ? 0 : finalW)
        let y = anchor.y - (signY > 0 ? 0 : finalH)
        return CGRect(x: x, y: y, width: finalW, height: finalH)
    }

    // MARK: - Selection chrome

    @ViewBuilder
    private func selectionChrome(imageRect: CGRect) -> some View {
        Rectangle()
            .strokeBorder(
                theme.accent,
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
            )
            .frame(width: imageRect.width, height: imageRect.height)
            .position(x: imageRect.midX, y: imageRect.midY)
            .allowsHitTesting(false)

        cornerHandle(.topLeft,     at: CGPoint(x: imageRect.minX, y: imageRect.minY))
        cornerHandle(.topRight,    at: CGPoint(x: imageRect.maxX, y: imageRect.minY))
        cornerHandle(.bottomLeft,  at: CGPoint(x: imageRect.minX, y: imageRect.maxY))
        cornerHandle(.bottomRight, at: CGPoint(x: imageRect.maxX, y: imageRect.maxY))

        floatingToolbar()
            .position(
                x: imageRect.midX,
                y: max(14, imageRect.minY - Self.toolbarGap - 14)
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
                .gesture(imageDragGesture)

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

    private var imageDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragOffset == .zero {
                    print("[ImageGesture] 2. drag onChanged FIRST tick elementId=\(element.id.uuidString.prefix(8)) translation=\(value.translation) startLocation=\(value.startLocation)")
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                print("[ImageGesture] 3. drag onEnded elementId=\(element.id.uuidString.prefix(8)) translation=\(value.translation) predictedEnd=\(value.predictedEndTranslation)")
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                element.normalizedX = clampNorm(element.normalizedX + Double(dxNorm))
                element.normalizedY = clampNorm(element.normalizedY + Double(dyNorm))
                element.updatedAt   = Date()
                dragOffset = .zero
                print("[ImageGesture] 3a. drag commit done normX=\(element.normalizedX) normY=\(element.normalizedY)")
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
                if resizeDelta == nil {
                    print("[ImageGesture] 4. resize handle onChanged FIRST tick elementId=\(element.id.uuidString.prefix(8)) corner=\(corner) translation=\(value.translation) startLocation=\(value.startLocation)")
                }
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                print("[ImageGesture] 5. resize handle onEnded elementId=\(element.id.uuidString.prefix(8)) corner=\(corner) translation=\(value.translation)")
                let base = CGRect(
                    x: element.normalizedX * pageSize.width,
                    y: element.normalizedY * pageSize.height,
                    width: element.normalizedWidth * pageSize.width,
                    height: element.normalizedHeight * pageSize.height
                )
                let new = resizedRect(base: base, corner: corner, translation: value.translation)
                element.normalizedX      = clampNorm(Double(new.minX) / Double(pageSize.width))
                element.normalizedY      = clampNorm(Double(new.minY) / Double(pageSize.height))
                element.normalizedWidth  = min(1, Double(new.width)  / Double(pageSize.width))
                element.normalizedHeight = min(1, Double(new.height) / Double(pageSize.height))
                element.updatedAt        = Date()
                resizeDelta = nil
                print("[ImageGesture] 5a. resize commit done normW=\(element.normalizedWidth) normH=\(element.normalizedHeight)")
            }
    }

    private func rotate90() {
        // .pi/2 radians per tap. The element model uses radians
        // (consistent with TextBlock); 4 taps = full rotation.
        let next = element.rotation + .pi / 2
        let twoPi = 2 * Double.pi
        element.rotation = next.truncatingRemainder(dividingBy: twoPi)
        element.updatedAt = Date()
    }

    private func clampNorm(_ v: Double) -> Double { max(0, min(1, v)) }
}

import SwiftData
import SwiftUI

/// Renders one V6 `PageElement` of kind `.stickyNote` as a coloured
/// card with in-place text editing. Follows the template established
/// by `TextElementView` / `ImageElementView` / `HighlightElementView`,
/// with two intentional UX deviations from the text element:
///
///   • **Single-tap-to-edit.** Sticky notes are quick-capture by
///     nature — a tap on a sticky drops the keyboard immediately
///     rather than requiring a tap-to-select then tap-to-edit
///     two-step. Documented in Step 7 design notes.
///   • **Long-press-to-select.** The "manipulate without editing"
///     gesture is long-press: it surfaces the selection chrome
///     (color picker + delete + resize handles + drag) without
///     entering the keyboard. Tap edits; long-press selects.
///
/// Step 7.1: selection chrome adds drag-to-move (card body) and
/// four corner-resize handles. Resize is **not aspect-locked** —
/// stickies are text containers; the user controls the shape.
/// Rotation handle is deliberately omitted (sticky chrome stays
/// simpler than image / PDF chrome). The drag/resize gesture math
/// mirrors `ImageElementView` exactly — transient @State deltas
/// applied to a `displayedRect`, committed to SwiftData on
/// `.onEnded`.
struct StickyNoteElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: StickyNoteContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    @Binding var isEditing: Bool
    let onDelete: () -> Void
    let onRequestSelect: () -> Void
    let onRequestEdit: () -> Void

    @Environment(\.theme) private var theme

    // Transient gesture deltas — kept local so a drag/resize tick
    // doesn't write SwiftData every frame; commits land on
    // `.onEnded`. Same pattern as `ImageElementView`.
    @State private var dragOffset: CGSize = .zero
    @State private var resizeDelta: ResizeDelta? = nil

    // MARK: - Constants

    /// Visual diameter of a corner handle. Hit-target is expanded
    /// to 32pt via `.contentShape(Rectangle().inset(by: -10))`
    /// (Apple HIG minimum).
    private static let handleSize: CGFloat = 12
    /// Smallest readable sticky in points (absolute, not page-
    /// normalised). Below this the card is unusable as a note.
    private static let minCardSize = CGSize(width: 80, height: 60)
    /// Largest sensible sticky — half the page in each axis. Beyond
    /// that the user wants a text element, not a sticky.
    private static let maxCardFraction: Double = 0.5

    private struct ResizeDelta: Equatable {
        var corner: Corner
        var translation: CGSize
    }
    private enum Corner: Equatable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    // MARK: - Body

    var body: some View {
        let base = baseRect
        let displayed = displayedRect(base: base)

        ZStack(alignment: .topLeading) {
            // Order is load-bearing — `.contentShape(Rectangle())`
            // MUST sit BEFORE `.position(...)` so the hit shape is
            // the card's actual rect, not the parent-filling rect
            // SwiftUI gives a positioned view. Step 7.1 had these
            // swapped; the result was every sticky absorbing every
            // tap on its page (because the contentShape became
            // page-sized) and the overlay's background-tap handler
            // never fired. Mirrors `ImageElementView.body`.
            card
                .frame(width: displayed.width, height: displayed.height)
                .overlay(textLayer)
                .overlay(borderOverlay)
                .overlay(deleteBadge, alignment: .bottomTrailing)
                .rotationEffect(.radians(element.rotation))
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded { onRequestEdit() }
                )
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.35)
                        .onEnded { _ in onRequestSelect() }
                )
                .gesture(
                    (isSelected && !isEditing) ? bodyDragGesture : nil
                )
                .position(x: displayed.midX, y: displayed.midY)

            if isSelected && !isEditing {
                colorPickerStrip(displayed: displayed)
                cornerHandle(.topLeft,
                             at: CGPoint(x: displayed.minX, y: displayed.minY))
                cornerHandle(.topRight,
                             at: CGPoint(x: displayed.maxX, y: displayed.minY))
                cornerHandle(.bottomLeft,
                             at: CGPoint(x: displayed.minX, y: displayed.maxY))
                cornerHandle(.bottomRight,
                             at: CGPoint(x: displayed.maxX, y: displayed.maxY))
            }
        }
        .frame(width: pageSize.width, height: pageSize.height,
               alignment: .topLeading)
        .onChange(of: content.text) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
        .onChange(of: content.colorVariant) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
    }

    // MARK: - Geometry

    private var baseRect: CGRect {
        CGRect(
            x: element.normalizedX * pageSize.width,
            y: element.normalizedY * pageSize.height,
            width: element.normalizedWidth * pageSize.width,
            height: element.normalizedHeight * pageSize.height
        )
    }

    private func displayedRect(base: CGRect) -> CGRect {
        if let r = resizeDelta {
            return resizedRect(base: base, corner: r.corner, translation: r.translation)
        }
        let cx = base.midX + dragOffset.width
        let cy = base.midY + dragOffset.height
        return CGRect(
            x: cx - base.width / 2,
            y: cy - base.height / 2,
            width: base.width,
            height: base.height
        )
    }

    /// Free (non-aspect-locked) corner resize. The opposite corner
    /// stays pinned in space; the dragged corner moves by the drag
    /// translation; width and height clamp to [minCardSize,
    /// maxCardFraction × pageSize] independently.
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
        let maxW = CGFloat(Self.maxCardFraction) * pageSize.width
        let maxH = CGFloat(Self.maxCardFraction) * pageSize.height
        let w = clamp(
            base.width  + signX * translation.width,
            min: Self.minCardSize.width,
            max: maxW
        )
        let h = clamp(
            base.height + signY * translation.height,
            min: Self.minCardSize.height,
            max: maxH
        )
        let x = anchor.x - (signX > 0 ? 0 : w)
        let y = anchor.y - (signY > 0 ? 0 : h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Card subviews

    private var card: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(cardColor)
            .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var textLayer: some View {
        if isEditing {
            StickyTextEditor(
                text: $content.text,
                isEditing: $isEditing,
                textColor: UIColor(stickyTextColor)
            )
            .padding(12)
        } else {
            Text(content.text.isEmpty ? "tap to edit" : content.text)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(
                    content.text.isEmpty
                        ? stickyTextColor.opacity(0.45)
                        : stickyTextColor
                )
                .padding(12)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .allowsHitTesting(false)  // taps fall through to the card
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        if isSelected && !isEditing {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    theme.accent,
                    style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                )
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var deleteBadge: some View {
        if isSelected && !isEditing {
            Button(action: onDelete) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(theme.accent)
                    .background(Circle().fill(theme.surfaceElevated))
            }
            .buttonStyle(.plain)
            .padding(6)
        }
    }

    private var cardColor: Color {
        theme.stickyNotePalette[content.colorVariant]
            ?? theme.stickyNotePalette["yellow"]
            ?? .yellow
    }

    /// Fixed dark grey reads on every sticky-palette variant in
    /// both themes — the palette was tuned to avoid per-colour
    /// contrast-flip branching.
    private var stickyTextColor: Color {
        Color(red: 0.15, green: 0.15, blue: 0.15)
    }

    // MARK: - Color picker

    /// Horizontal swatch row floating above the card. Positioned in
    /// page coords (not on the card overlay) so the resize handles
    /// can sit at the card corners without overlapping the picker.
    @ViewBuilder
    private func colorPickerStrip(displayed: CGRect) -> some View {
        HStack(spacing: 8) {
            ForEach(StickyNoteCommit.paletteKeys, id: \.self) { key in
                swatch(key: key)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(theme.surfaceElevated))
        .overlay(Capsule().stroke(theme.borderSubtle, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
        .position(
            x: displayed.midX,
            y: max(18, displayed.minY - 22)
        )
    }

    private func swatch(key: String) -> some View {
        let isActive = content.colorVariant == key
        let fill = theme.stickyNotePalette[key] ?? .yellow
        return Circle()
            .fill(fill)
            .frame(width: 22, height: 22)
            .overlay(
                Circle().stroke(
                    isActive ? theme.accent : theme.borderSubtle,
                    lineWidth: isActive ? 2 : 0.5
                )
            )
            .contentShape(Circle())
            .onTapGesture { content.colorVariant = key }
    }

    // MARK: - Corner handles

    private func cornerHandle(_ corner: Corner, at point: CGPoint) -> some View {
        Circle()
            .fill(theme.accent)
            .overlay(
                Circle().stroke(theme.surfaceElevated, lineWidth: 1.5)
            )
            .frame(width: Self.handleSize, height: Self.handleSize)
            // 32pt hit target (Apple HIG min) without bloating the
            // visual size — matches `ImageElementView.cornerHandle`.
            .contentShape(Rectangle().inset(by: -10))
            .position(point)
            .gesture(resizeGesture(for: corner))
    }

    // MARK: - Gestures

    /// Card-body drag — only active when selected AND not editing.
    /// Conflicts with text editing are prevented by the
    /// `(isSelected && !isEditing) ? bodyDragGesture : nil` ternary
    /// at the call site.
    private var bodyDragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                dragOffset = value.translation
            }
            .onEnded { value in
                let dxNorm = value.translation.width  / pageSize.width
                let dyNorm = value.translation.height / pageSize.height
                let newX = element.normalizedX + Double(dxNorm)
                let newY = element.normalizedY + Double(dyNorm)
                // Clamp so the card stays inside the page.
                let maxX = 1 - element.normalizedWidth
                let maxY = 1 - element.normalizedHeight
                element.normalizedX = max(0, min(maxX, newX))
                element.normalizedY = max(0, min(maxY, newY))
                element.updatedAt   = Date()
                dragOffset = .zero
            }
    }

    private func resizeGesture(for corner: Corner) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resizeDelta = ResizeDelta(corner: corner, translation: value.translation)
            }
            .onEnded { value in
                let new = resizedRect(
                    base: baseRect,
                    corner: corner,
                    translation: value.translation
                )
                let normX = Double(new.minX)  / Double(pageSize.width)
                let normY = Double(new.minY)  / Double(pageSize.height)
                let normW = Double(new.width)  / Double(pageSize.width)
                let normH = Double(new.height) / Double(pageSize.height)
                element.normalizedX      = max(0, min(1 - normW, normX))
                element.normalizedY      = max(0, min(1 - normH, normY))
                element.normalizedWidth  = max(0.01, min(1, normW))
                element.normalizedHeight = max(0.01, min(1, normH))
                element.updatedAt        = Date()
                resizeDelta = nil
            }
    }

    // MARK: - Helpers

    private func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        Swift.max(lo, Swift.min(hi, value))
    }
}

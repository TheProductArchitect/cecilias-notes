import SwiftUI

// MARK: - RadialToolWheel

/// 8-segment radial picker, summoned by the Pencil Pro squeeze gesture.
///
/// Tap a segment to select; tap outside to dismiss. Segments are arranged
/// at equal angles around `center`, each rendered as a 64pt circular icon
/// over `.ultraThinMaterial`.
///
/// Keep this view dumb — it just renders + emits taps. The host (EditorView)
/// owns the visibility state and routes selections to the view-model.
struct RadialToolWheel: View {

    let items: [WheelItem]
    let center: CGPoint
    let onSelect: (WheelItem) -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visible = false

    private let radius: CGFloat = 100        // distance from centre to each segment's centre
    private let segmentSize: CGFloat = 64

    var body: some View {
        ZStack {
            // Tap-outside scrim — fully transparent, captures dismiss taps.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            // Segments
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                segmentView(item: item, at: position(forIndex: index))
            }
        }
        .scaleEffect(reduceMotion ? 1.0 : (visible ? 1.0 : 0.85))
        .opacity(visible ? 1.0 : 0)
        .onAppear {
            if reduceMotion {
                visible = true
            } else {
                withAnimation(.inkSpring(CeciliasNotesSpring.snappy)) { visible = true }
            }
        }
    }

    private func segmentView(item: WheelItem, at point: CGPoint) -> some View {
        Button {
            HapticManager.shared.toolSwitched()
            onSelect(item)
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay(
                        Circle().strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                    )
                Image(systemName: item.systemImage)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(.inkTextPrimary)
            }
            .frame(width: segmentSize, height: segmentSize)
        }
        .buttonStyle(.inkPressable)
        .position(point)
        .accessibilityLabel(item.displayName)
    }

    /// Place segments on a circle starting at the top (-90°) and going clockwise.
    private func position(forIndex index: Int) -> CGPoint {
        let angle = (CGFloat(index) / CGFloat(items.count)) * 2 * .pi - .pi / 2
        return CGPoint(
            x: center.x + radius * cos(angle),
            y: center.y + radius * sin(angle)
        )
    }
}

// MARK: - WheelItem

/// One slot on the radial wheel. Either a tool to activate or a one-shot
/// action (undo, redo, focus toggle). Designed so the wheel composition
/// is data-driven — Settings → Apple Pencil customisation can later let
/// the user override the default eight (TODO).
enum WheelItem: Hashable {
    case tool(CeciliasNotesTool.Identity)
    case undo
    case redo
    case toggleFocus
    case exitFocus

    var systemImage: String {
        switch self {
        case .tool(let id):     return id.systemImage
        case .undo:             return "arrow.uturn.backward"
        case .redo:             return "arrow.uturn.forward"
        case .toggleFocus:      return "rectangle.portrait"
        case .exitFocus:        return "rectangle.portrait.inset.filled"
        }
    }

    var displayName: String {
        switch self {
        case .tool(let id):     return id.displayName
        case .undo:             return "Undo"
        case .redo:             return "Redo"
        case .toggleFocus:      return "Focus Mode"
        case .exitFocus:        return "Exit Focus"
        }
    }

    /// Default eight items shown in normal editing mode.
    /// TODO: Settings → Apple Pencil should let users override these eight.
    static let defaultSet: [WheelItem] = [
        .tool(.pen), .tool(.pencil), .tool(.highlighter), .tool(.eraser),
        .tool(.lasso), .undo, .redo, .toggleFocus,
    ]

    /// Reduced set when the editor is in Focus Mode — the user has
    /// deliberately hidden everything; surface only undo/redo/exit.
    static let focusModeSet: [WheelItem] = [
        .undo, .redo, .exitFocus,
    ]
}

import SwiftUI

// MARK: - ToolbarEdge

/// Which screen edge the floating tool palette is anchored to.
///
/// The palette layout is determined by the edge's `axis`:
///   • `.top`    / `.bottom` → horizontal layout (HStack)
///   • `.left`   / `.right`  → vertical   layout (VStack)
///
/// Persisted **per orientation** in `@AppStorage` so the user's
/// preferred edge in portrait can differ from their preferred edge in
/// landscape — and rotation always animates to the right one.
enum ToolbarEdge: String, CaseIterable, Codable {
    case top, right, bottom, left

    enum Axis { case horizontal, vertical }

    var axis: Axis {
        switch self {
        case .top, .bottom:  return .horizontal
        case .left, .right:  return .vertical
        }
    }

    /// SwiftUI alignment for pinning the palette inside its parent.
    var alignment: Alignment {
        switch self {
        case .top:    return .top
        case .right:  return .trailing
        case .bottom: return .bottom
        case .left:   return .leading
        }
    }

    /// Snaps a free-form release point inside `parentSize` to the nearest
    /// edge. Distance is measured to the *centre* of each edge so the snap
    /// feels predictable from the middle of the screen.
    static func nearestEdge(to point: CGPoint, in parentSize: CGSize) -> ToolbarEdge {
        let dTop    = point.y
        let dBottom = parentSize.height - point.y
        let dLeft   = point.x
        let dRight  = parentSize.width  - point.x

        let smallest = min(dTop, dBottom, dLeft, dRight)
        switch smallest {
        case dTop:    return .top
        case dBottom: return .bottom
        case dLeft:   return .left
        default:      return .right
        }
    }
}

// MARK: - Per-orientation persistence

/// Reads/writes the tool palette's edge for the current orientation.
///
/// Two AppStorage keys (`portraitEdge`, `landscapeEdge`) are kept in
/// `@AppStorage` directly inside `ToolPaletteView`. This struct is
/// the place to keep the orientation-detection logic so the rest of
/// the view stays small and readable.
struct ToolbarEdgeBinding {

    /// Default values — match the spec.
    static let portraitDefault:  ToolbarEdge = .top
    static let landscapeDefault: ToolbarEdge = .right

    /// Returns true when the parent view is in landscape orientation.
    /// Width-greater-than-height is the simplest reliable signal — works
    /// for iPad split view, Stage Manager, and rotation alike.
    static func isLandscape(_ parentSize: CGSize) -> Bool {
        parentSize.width > parentSize.height
    }
}

import Foundation
import UIKit

// MARK: - TextBlockInteractionState

/// State machine for a single text block's interaction lifecycle.
enum TextBlockInteractionState: Equatable {
    case idle        // visible but not focused
    case selected    // tapped once — shows resize handles, no keyboard
    case editing     // keyboard visible, textView.isEditable = true

    var isEditing: Bool { self == .editing }
    var isSelected: Bool { self == .selected || self == .editing }
}

// MARK: - TextBlockLayoutState

/// Live layout for a text block in page-normalised coordinates (0.0–1.0).
/// Derived from the SwiftData model; mutated during drag/resize, then persisted on commit.
struct TextBlockLayoutState: Equatable {
    var id: UUID
    var normalizedRect: CGRect   // origin + size in page-normalised space
    var zIndex: Int

    init(from block: TextBlock) {
        id            = block.id
        normalizedRect = CGRect(x: block.x, y: block.y, width: block.width, height: block.height)
        zIndex         = block.zIndex
    }

    /// Convert normalised rect → point rect given page size.
    func pointRect(pageSize: CGSize) -> CGRect {
        CGRect(
            x:      normalizedRect.origin.x * pageSize.width,
            y:      normalizedRect.origin.y * pageSize.height,
            width:  normalizedRect.width    * pageSize.width,
            height: normalizedRect.height   * pageSize.height
        )
    }

    /// Convert a point rect → normalised rect given page size.
    static func normalise(_ pointRect: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(
            x:      pointRect.origin.x / pageSize.width,
            y:      pointRect.origin.y / pageSize.height,
            width:  pointRect.width    / pageSize.width,
            height: pointRect.height   / pageSize.height
        )
    }
}

// MARK: - ResizeHandle

/// The 8 resize handles placed at corners and edge midpoints.
enum ResizeHandle: CaseIterable {
    case topLeft, topCenter, topRight
    case middleLeft,            middleRight
    case bottomLeft, bottomCenter, bottomRight

    var cursor: UIPointerShape { .path(UIBezierPath(ovalIn: CGRect(origin: .zero, size: CGSize(width: 10, height: 10)))) }

    /// Normalised anchor point within the block's bounding rect.
    var anchor: CGPoint {
        switch self {
        case .topLeft:      return CGPoint(x: 0,   y: 0)
        case .topCenter:    return CGPoint(x: 0.5, y: 0)
        case .topRight:     return CGPoint(x: 1,   y: 0)
        case .middleLeft:   return CGPoint(x: 0,   y: 0.5)
        case .middleRight:  return CGPoint(x: 1,   y: 0.5)
        case .bottomLeft:   return CGPoint(x: 0,   y: 1)
        case .bottomCenter: return CGPoint(x: 0.5, y: 1)
        case .bottomRight:  return CGPoint(x: 1,   y: 1)
        }
    }

    /// Which edges this handle moves when dragged.
    var movesLeft: Bool   { self == .topLeft   || self == .middleLeft   || self == .bottomLeft }
    var movesRight: Bool  { self == .topRight  || self == .middleRight  || self == .bottomRight }
    var movesTop: Bool    { self == .topLeft   || self == .topCenter    || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottomCenter || self == .bottomRight }
}

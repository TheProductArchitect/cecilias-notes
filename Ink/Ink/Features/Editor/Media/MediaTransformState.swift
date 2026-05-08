import Foundation
import UIKit

// MARK: - MediaAttachmentInteractionState

enum MediaAttachmentInteractionState: Equatable {
    case idle           // image rendered, no chrome
    case selected       // accent border + 8 handles + rotation handle
    case transforming   // actively moving, scaling, or rotating
}

// MARK: - MediaTransformHandle

enum MediaTransformHandle: CaseIterable, Equatable {
    // Scale handles
    case topLeft, topCenter, topRight
    case middleLeft, middleRight
    case bottomLeft, bottomCenter, bottomRight
    // Rotation
    case rotation

    /// Normalised anchor point within the bounding rect (same as ResizeHandle).
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
        case .rotation:     return CGPoint(x: 0.5, y: -0.12) // above top-centre
        }
    }

    var isCorner: Bool {
        self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight
    }
    var isEdge: Bool {
        self == .topCenter || self == .middleLeft || self == .middleRight || self == .bottomCenter
    }
    var movesLeft: Bool   { self == .topLeft || self == .middleLeft || self == .bottomLeft }
    var movesRight: Bool  { self == .topRight || self == .middleRight || self == .bottomRight }
    var movesTop: Bool    { self == .topLeft || self == .topCenter || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottomCenter || self == .bottomRight }
}

// MARK: - MediaTransformHandle Identifiable

extension MediaTransformHandle: Identifiable {
    var id: String { "\(self)" }
}

// MARK: - MediaLayoutState

/// Live layout for a media attachment in page-normalised coordinates.
struct MediaLayoutState: Equatable {
    var id: UUID
    var normalizedRect: CGRect
    var rotation: Double   // radians
    var zIndex: Int
    var opacity: Double

    init(from attachment: MediaAttachment) {
        id            = attachment.id
        normalizedRect = CGRect(x: attachment.x, y: attachment.y,
                                width: attachment.width, height: attachment.height)
        rotation      = attachment.rotation
        zIndex        = attachment.zIndex
        opacity       = attachment.opacity
    }

    func pointRect(pageSize: CGSize) -> CGRect {
        CGRect(
            x:      normalizedRect.origin.x * pageSize.width,
            y:      normalizedRect.origin.y * pageSize.height,
            width:  normalizedRect.width    * pageSize.width,
            height: normalizedRect.height   * pageSize.height
        )
    }

    static func normalise(_ pointRect: CGRect, pageSize: CGSize) -> CGRect {
        CGRect(
            x:      pointRect.origin.x / pageSize.width,
            y:      pointRect.origin.y / pageSize.height,
            width:  pointRect.width    / pageSize.width,
            height: pointRect.height   / pageSize.height
        )
    }
}

// MARK: - AspectRatioLock

enum AspectRatioLock: String, CaseIterable {
    case free   = "Free"
    case square = "1:1"
    case four3  = "4:3"
    case wide   = "16:9"
    case a4     = "A4"
    case letter = "Letter"

    var ratio: CGFloat? {
        switch self {
        case .free:   return nil
        case .square: return 1
        case .four3:  return 4.0 / 3.0
        case .wide:   return 16.0 / 9.0
        case .a4:     return 210.0 / 297.0
        case .letter: return 8.5 / 11.0
        }
    }
}

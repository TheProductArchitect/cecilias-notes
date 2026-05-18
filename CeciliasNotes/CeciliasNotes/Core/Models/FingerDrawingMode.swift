import Foundation

/// User's policy for finger drawing on the canvas. Step 3
/// generalises the V5 binary toggle into three modes so the app
/// can adapt to finger-only users automatically while still letting
/// pencil users force pencilOnly (the common pro choice) and
/// allowing curious users to override either direction.
///
/// Resolved into `PKCanvasViewDrawingPolicy` by combining with
/// `InputCapabilityDetector.hasPencil`:
///   • `.auto`   → `.pencilOnly` when a pencil has been seen,
///                 `.anyInput` otherwise (finger-only users get
///                 finger drawing without touching Settings)
///   • `.always` → `.anyInput`   (finger always draws regardless)
///   • `.never`  → `.pencilOnly` (force pencil even on finger
///                 devices — useful for shared iPads where the
///                 owner wants to lock down drawing)
enum FingerDrawingMode: String, CaseIterable, Codable {
    case auto
    case always
    case never

    var displayName: String {
        switch self {
        case .auto:    return "Auto"
        case .always:  return "Always Allow Finger"
        case .never:   return "Pencil Only"
        }
    }

    var detailDescription: String {
        switch self {
        case .auto:
            return "Follows your iPad. If an Apple Pencil is detected, only Pencil draws. Without a Pencil, finger can also draw."
        case .always:
            return "Finger always draws. Two-finger pan and pinch still work for navigation."
        case .never:
            return "Only Apple Pencil draws. Finger gestures scroll and zoom."
        }
    }

    /// Resolves the mode against the current detection state into
    /// the bool the existing canvas plumbing expects.
    func fingerDrawingEnabled(hasPencil: Bool) -> Bool {
        switch self {
        case .auto:    return !hasPencil
        case .always:  return true
        case .never:   return false
        }
    }
}

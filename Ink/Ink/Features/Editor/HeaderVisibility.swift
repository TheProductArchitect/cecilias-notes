import Foundation

/// Three-state visibility model for the redesigned notebook header.
///
/// The header is the editorial cover-tone strip at the top of the
/// editor. It surfaces identity (back chevron + subject + title) and
/// meta (page count + last-opened) and gets out of the way the moment
/// the user starts writing.
///
/// Transitions:
///   • `.visible` → `.hiddenWhileWriting` on the first PencilKit stroke
///     (or keyboard appearance) after the notebook opens.
///   • `.hiddenWhileWriting` → `.visibleManual` when the user taps the
///     3pt return bar at the top of the canvas, or swipes down from
///     the top edge.
///   • `.visibleManual` → `.hiddenWhileWriting` 2 seconds after the
///     next stroke begins. The grace period is intentional: the user
///     just chose to see the bar, so we don't fight the next stroke
///     by hiding immediately.
///
/// State is owned by `EditorViewModel.headerVisibility`. The view tree
/// reads it to drive the slide animation and the 3pt return bar.
enum HeaderVisibility {
    /// Notebook just opened — header is visible and the user hasn't
    /// yet touched the canvas.
    case visible

    /// User is writing (or has written). Header is off-screen; only
    /// the 3pt cover-tone return bar remains at the top.
    case hiddenWhileWriting

    /// User reached up and revealed the header by tapping the bar or
    /// swiping down. Header is visible; the next stroke arms a 2-second
    /// re-hide timer.
    case visibleManual

    /// True iff the header should be drawn into the layout.
    var isHeaderVisible: Bool {
        switch self {
        case .visible, .visibleManual: return true
        case .hiddenWhileWriting:      return false
        }
    }
}

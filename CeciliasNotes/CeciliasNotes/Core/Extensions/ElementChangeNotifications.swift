import Foundation

/// Element-overlay change signals that must be visible to BOTH app
/// targets. They historically lived next to the iOS overlay that
/// observes each one, but `TrashService.postRestoreRefetch` (shared,
/// Features/Library) posts them too — and the overlay files are
/// iOS-only, so the Mac target failed to compile the names. The Mac
/// side has no observers (doc mode refetches via `@Query`); posting
/// with no listeners is fine, failing to compile is not.
///
/// The names that DIDN'T move (`textElementsChanged`,
/// `audioElementsChanged`, `shapeElementsChanged`) stay with their
/// commit helpers, which are already members of both targets.
extension Notification.Name {
    /// Posted whenever a sticky element is created, restored, or
    /// soft-deleted. Carried over from the legacy `StickyNoteStore`
    /// so consumers (annotation list sheet, customise count row)
    /// keep working without notification-name churn.
    static let stickyNotesChanged = Notification.Name("stickyNotesChanged")

    /// Posted by the image import pipeline, the image overlay's
    /// soft-delete path, and trash restore so listeners can refetch
    /// from SwiftData without polling. (Relocated from
    /// `MediaAttachmentStore` in Step 4, then here for the Mac.)
    static let mediaAttachmentsChanged = Notification.Name("mediaAttachmentsChanged")

    /// Posted by `HighlightCommit`, the highlight overlay's
    /// soft-delete handler, and trash restore whenever a highlight
    /// element is inserted or deleted. Overlays refetch; the
    /// notification is a "now would be a good time to refetch"
    /// hint, not a payload.
    static let highlightElementsChanged = Notification.Name("highlightElementsChanged")

    /// Posted by `LassoGroupOps` (and trash restore of stroke
    /// elements) after any operation rewrites
    /// `StrokeContent.strokeData` or soft-deletes a whole stroke
    /// element, so the canvas coordinator can reload the affected
    /// pages' PKCanvasViews. userInfo: `"pageIds": [UUID]`.
    static let strokeContentRewritten = Notification.Name("strokeContentRewritten")
}

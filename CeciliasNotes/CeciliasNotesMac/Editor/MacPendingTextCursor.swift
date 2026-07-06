import Foundation

/// One-shot click Y within a text block — consumed when the editor attaches.
@MainActor
enum MacPendingTextCursor {
    private static var clickYByElementId: [UUID: CGFloat] = [:]

    static func set(elementId: UUID, clickYInBlock: CGFloat) {
        clickYByElementId[elementId] = clickYInBlock
    }

    static func take(elementId: UUID) -> CGFloat? {
        clickYByElementId.removeValue(forKey: elementId)
    }
}

import CoreGraphics
import Foundation

/// Cross-platform Handoff payload for continuing page editing between
/// iPad, iPhone, and Mac. Activity type must appear in each target's
/// `NSUserActivityTypes` Info.plist entry.
enum PageHandoff {

    static let activityType = "app.ceciliasnotes.page"
    static let notebookIdKey = "notebookId"
    static let pageIdKey = "pageId"
    static let scrollOffsetKey = "scrollOffset"
    static let zoomKey = "zoom"

    struct Payload: Equatable {
        let notebookId: UUID
        let pageId: UUID
        let scrollOffset: CGFloat
        let zoom: CGFloat
    }

    static func userInfo(
        notebookId: UUID,
        pageId: UUID,
        scrollOffset: CGFloat = 0,
        zoom: CGFloat = 1
    ) -> [String: Any] {
        [
            notebookIdKey: notebookId.uuidString,
            pageIdKey: pageId.uuidString,
            scrollOffsetKey: scrollOffset,
            zoomKey: zoom,
        ]
    }

    static func parse(_ userInfo: [AnyHashable: Any]?) -> Payload? {
        guard let userInfo else { return nil }
        let notebookString = userInfo[notebookIdKey] as? String
            ?? (userInfo[notebookIdKey] as? UUID)?.uuidString
        let pageString = userInfo[pageIdKey] as? String
            ?? (userInfo[pageIdKey] as? UUID)?.uuidString
        guard let notebookString,
              let notebookId = UUID(uuidString: notebookString),
              let pageString,
              let pageId = UUID(uuidString: pageString)
        else { return nil }

        return Payload(
            notebookId: notebookId,
            pageId: pageId,
            scrollOffset: scalar(userInfo[scrollOffsetKey]) ?? 0,
            zoom: scalar(userInfo[zoomKey]) ?? 1
        )
    }

    private static func scalar(_ value: Any?) -> CGFloat? {
        switch value {
        case let number as CGFloat: return number
        case let number as Double: return CGFloat(number)
        case let number as Float: return CGFloat(number)
        case let number as Int: return CGFloat(number)
        case let number as NSNumber: return CGFloat(truncating: number)
        default: return nil
        }
    }
}

#if os(macOS)
typealias MacHandoff = PageHandoff
#endif

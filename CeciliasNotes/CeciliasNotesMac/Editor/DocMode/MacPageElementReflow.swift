import Foundation
import SwiftData

/// Packs non-stroke elements into a vertical stack in normalized
/// coordinates so Mac flow-layout edits sync cleanly to iPad.
@MainActor
enum MacPageElementReflow {
    static func packVerticalLayout(pageId: UUID) {
        let context = StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [
                SortDescriptor(\PageElement.normalizedY),
                SortDescriptor(\PageElement.zIndex),
            ]
        )
        guard let elements = try? context.fetch(descriptor) else { return }
        let content = elements.filter { $0.kind != .stroke }
        guard !content.isEmpty else { return }

        let pageHeight = StorageService.shared.fetchPage(id: pageId)?
            .pageSize.pointSize.height ?? PageSize.a4.pointSize.height
        var cursor = MacDocPageLayout.normalizedTopMargin(pageHeight: pageHeight)
        var changed = false

        for element in content {
            if abs(element.normalizedY - cursor) > 0.002 {
                element.normalizedY = cursor
                element.updatedAt = Date()
                changed = true
            }
            cursor = min(0.92, cursor + element.normalizedHeight + 0.02)
        }

        if changed {
            Page.clearInkbookStash(forPageId: pageId, context: context)
            try? context.save()
        }
    }
}

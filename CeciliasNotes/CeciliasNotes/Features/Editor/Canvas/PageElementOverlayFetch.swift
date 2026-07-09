import Foundation
import SwiftData

/// Shared SwiftData fetch helpers for per-page element overlays.
/// Overlays cache results in `@State` and reload only on
/// notification — never on every `body` pass.
enum PageElementOverlayFetch {

    static func elements(
        pageId: UUID,
        kind: ElementKind,
        context: ModelContext,
        includeCreatedAtSort: Bool = true
    ) -> [PageElement] {
        var sort: [SortDescriptor<PageElement>] = [SortDescriptor(\.zIndex)]
        if includeCreatedAtSort {
            sort.append(SortDescriptor(\.createdAt))
        }
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            },
            sortBy: sort
        )
        let all = (try? context.fetch(descriptor)) ?? []
        return all.filter { $0.kind == kind }.dedupedById()
    }

    /// PDF parent lookup for highlight projection.
    static func pdfPageElementsByContentId(
        pageId: UUID,
        context: ModelContext
    ) -> [UUID: PageElement] {
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let all = (try? context.fetch(descriptor)) ?? []
        var map: [UUID: PageElement] = [:]
        for element in all where element.kind == .pdfPage {
            if let content = element.pdfPageContent {
                map[content.id] = element
            }
        }
        return map
    }
}

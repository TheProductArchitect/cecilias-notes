import AppKit
import Foundation
import SwiftData
import SwiftUI

// MARK: - Measured block heights (top-anchored placement)

struct MacDocBlockHeightKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Auto-add pages when content reaches the lower half

@MainActor
enum MacPageAutoAdd {
    private static var lastAutoAddDate = Date.distantPast

    /// When typing on the last page and content crosses the page
    /// midpoint, append a blank page (mirrors iPad `considerAutoAddAfterElement`).
    static func considerAfterTextGrowth(
        notebook: Notebook,
        page: Page,
        normalizedMaxY: Double,
        storage: StorageService
    ) {
        guard notebook.autoAddPagesOnScroll else { return }
        let pages = storage.fetchPages(in: notebook)
        guard pages.last?.id == page.id else { return }
        guard normalizedMaxY >= 0.5 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoAddDate) > 1.0 else { return }
        lastAutoAddDate = now
        MacStateUpdates.deferred {
            _ = MacPageEditing.addPage(in: notebook, after: page, storage: storage)
        }
    }
}

// MARK: - Page overflow reconciliation

@MainActor
enum MacPageOverflow {
    /// Splits any text blocks that extend past the page bottom so
    /// overflow always lands on the next page instead of being clipped.
    static func reconcilePage(_ pageId: UUID) {
        MacPageElementReflow.packVerticalLayout(pageId: pageId)
        let storage = StorageService.shared
        guard let page = storage.fetchPage(id: pageId) else { return }
        let pageSize = page.pageSize.pointSize
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [
                SortDescriptor(\PageElement.normalizedY),
                SortDescriptor(\PageElement.zIndex),
            ]
        )
        guard let elements = try? storage.context.fetch(descriptor) else { return }
        var originY = MacDocPageLayout.topMargin
        for element in elements where element.kind == .text {
            guard let content = element.textContent else { continue }
            if let split = MacTextElementSplitter.splitIfNeeded(
                element: element,
                content: content,
                pageSize: pageSize,
                originY: originY
            ) {
                MacRecordingSession.shared.retargetIfWriting(
                    from: element.id,
                    to: split.continuationElementId,
                    consumedUTF16: split.overflowStartUTF16
                )
            }
            originY += CGFloat(element.normalizedHeight) * pageSize.height + MacDocPageLayout.blockSpacing
        }
    }
}

// MARK: - Overflow split (Mac port of `TextElementSplitter`)

@MainActor
enum MacTextElementSplitter {
    private static let bottomPadding: CGFloat = 6

    /// Outcome of an overflow split. `overflowStartUTF16` is the UTF-16
    /// offset within the element's pre-split text where the continuation
    /// begins — the live-transcription session uses it to keep writing
    /// only the unconsumed tail into the continuation block.
    struct SplitResult {
        let continuationElementId: UUID
        let overflowStartUTF16: Int
    }

    @discardableResult
    static func splitIfNeeded(
        element: PageElement,
        content: TextContent,
        pageSize: CGSize,
        originY: CGFloat
    ) -> SplitResult? {
        let attributed = current(content)
        guard attributed.length > 0 else { return nil }

        let margin = MacDocPageLayout.horizontalMargin
        let contentWidth = max(40, pageSize.width - 2 * margin)
        let contentBottom = MacPageElementReflow.contentBottomPoints(pageId: element.pageId)
        let availableHeight = max(40, contentBottom - originY - bottomPadding)

        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)

        guard measured > availableHeight else { return nil }

        let splitIndex = findSplitIndex(
            attributed: attributed,
            width: contentWidth,
            available: availableHeight
        )
        guard splitIndex > 0, splitIndex < attributed.length else { return nil }

        let snapped = snapToBoundary(attributed.string, near: splitIndex)
        guard snapped > 0, snapped < attributed.length else { return nil }

        let fit = attributed.attributedSubstring(from: NSRange(location: 0, length: snapped))
        var overflowStart = snapped
        let nsText = attributed.string as NSString
        while overflowStart < nsText.length {
            let ch = nsText.character(at: overflowStart)
            guard ch == 0x0A || ch == 0x20 else { break }
            overflowStart += 1
        }
        guard overflowStart < attributed.length else { return nil }
        let overflow = attributed.attributedSubstring(
            from: NSRange(location: overflowStart, length: attributed.length - overflowStart)
        )

        commit(attributed: fit, into: content)
        Page.clearInkbookStash(forPageId: element.pageId, context: StorageService.shared.context)
        guard let continuationId = placeOverflow(
            overflow: overflow,
            afterPageId: element.pageId,
            notebookId: element.notebookId,
            source: content.source
        ) else { return nil }
        return SplitResult(
            continuationElementId: continuationId,
            overflowStartUTF16: overflowStart
        )
    }

    private static func current(_ content: TextContent) -> NSAttributedString {
        MacRichTextCodec.decode(from: content)
    }

    private static func commit(attributed value: NSAttributedString, into content: TextContent) {
        let plain = value.string
        if content.text != plain { content.text = plain }
        if let data = MacRichTextCodec.encode(value), content.attributedTextData != data {
            content.attributedTextData = data
        }
        content.updatedAt = Date()
    }

    private static func placeOverflow(
        overflow: NSAttributedString,
        afterPageId: UUID,
        notebookId: UUID,
        source: TextSource
    ) -> UUID? {
        let storage = StorageService.shared
        let context = storage.context

        let notebookDescriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId }
        )
        guard let notebook = try? context.fetch(notebookDescriptor).first,
              let parentPage = storage.fetchPage(id: afterPageId) else {
            return nil
        }

        let allPages = storage.fetchPages(in: notebook).sorted { $0.pageNumber < $1.pageNumber }
        let nextPage: Page
        if let existing = allPages.first(where: { $0.pageNumber == parentPage.pageNumber + 1 }) {
            nextPage = existing
        } else if let made = try? storage.createPage(
            in: notebook,
            after: parentPage.pageNumber,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        ) {
            nextPage = made
        } else {
            return nil
        }

        let pageWidth = nextPage.pageSize.pointSize.width
        let topY = MacDocPageLayout.normalizedTopMargin(pageHeight: nextPage.pageSize.pointSize.height)
        let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageWidth)
        let contentWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageWidth)

        let pid = nextPage.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let existingOnNext = (try? context.fetch(descriptor)) ?? []
            .filter { $0.kind == .text }
        if let reuse = existingOnNext.first(where: { existing in
            guard let existingText = existing.textContent?.text else { return false }
            return existingText.isEmpty || existingText == overflow.string
        }) {
            if let content = reuse.textContent {
                commit(attributed: overflow, into: content)
                reuse.updatedAt = Date()
                try? context.save()
            }
            return reuse.id
        }

        let openY: Double
        if existingOnNext.isEmpty {
            openY = topY
        } else {
            let lowestBottom = existingOnNext
                .map { $0.normalizedY + $0.normalizedHeight }
                .max() ?? topY
            openY = min(0.95, max(topY, lowestBottom + 0.01))
        }

        let element = PageElement(
            id: UUID(),
            pageId: nextPage.id,
            notebookId: notebookId,
            kind: .text,
            normalizedX: marginX,
            normalizedY: openY,
            normalizedWidth: contentWidth,
            normalizedHeight: 0.08,
            zIndex: (existingOnNext.map(\.zIndex).max() ?? 0) + 1
        )
        let content = TextContent(
            text: overflow.string,
            source: source,
            size: .body,
            attributedTextData: MacRichTextCodec.encode(overflow)
        )
        element.textContent = content
        context.insert(element)
        try? context.save()
        return element.id
    }

    private static func findSplitIndex(
        attributed: NSAttributedString,
        width: CGFloat,
        available: CGFloat
    ) -> Int {
        var lo = 1
        var hi = attributed.length
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: mid))
            let h = ceil(prefix.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            if h <= available {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Walks backwards (UTF-16 domain, matching `findSplitIndex`) looking
    /// for the nearest newline, then the nearest whitespace, within a
    /// 120-unit window. Returning UTF-16 offsets keeps the split ranges
    /// aligned with `NSAttributedString` — mixing in `Character` indices
    /// drifts on emoji and can cut a surrogate pair in half.
    private static func snapToBoundary(_ s: String, near index: Int) -> Int {
        let ns = s as NSString
        let safeIdx = min(max(0, index), ns.length)
        let windowStart = max(0, safeIdx - 120)
        var whitespaceCandidate: Int?
        var i = safeIdx - 1
        while i >= windowStart {
            let ch = ns.character(at: i)
            if ch == 0x0A { return i + 1 }
            if whitespaceCandidate == nil,
               let scalar = Unicode.Scalar(ch),
               CharacterSet.whitespaces.contains(scalar) {
                whitespaceCandidate = i + 1
            }
            i -= 1
        }
        return whitespaceCandidate ?? safeIdx
    }
}

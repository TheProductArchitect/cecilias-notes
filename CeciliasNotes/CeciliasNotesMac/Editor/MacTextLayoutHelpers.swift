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

// MARK: - Overflow split (Mac port of `TextElementSplitter`)

@MainActor
enum MacTextElementSplitter {
    private static let bottomPadding: CGFloat = 6

    @discardableResult
    static func splitIfNeeded(
        element: PageElement,
        content: TextContent,
        pageSize: CGSize,
        originY: CGFloat
    ) -> Bool {
        let attributed = current(content)
        guard attributed.length > 0 else { return false }

        let margin = MacDocPageLayout.horizontalMargin
        let contentWidth = max(40, pageSize.width - 2 * margin)
        let availableHeight = max(40, pageSize.height - originY - bottomPadding)

        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)

        guard measured > availableHeight else { return false }

        let splitIndex = findSplitIndex(
            attributed: attributed,
            width: contentWidth,
            available: availableHeight
        )
        guard splitIndex > 0, splitIndex < attributed.length else { return false }

        let snapped = snapToBoundary(attributed.string, near: splitIndex)
        guard snapped > 0, snapped < attributed.length else { return false }

        let fit = attributed.attributedSubstring(from: NSRange(location: 0, length: snapped))
        var overflowStart = snapped
        let chars = Array(attributed.string)
        while overflowStart < chars.count, (chars[overflowStart] == "\n" || chars[overflowStart] == " ") {
            overflowStart += 1
        }
        guard overflowStart < attributed.length else { return false }
        let overflow = attributed.attributedSubstring(
            from: NSRange(location: overflowStart, length: attributed.length - overflowStart)
        )

        commit(attributed: fit, into: content)
        Page.clearInkbookStash(forPageId: element.pageId, context: StorageService.shared.context)
        placeOverflow(overflow: overflow, afterPageId: element.pageId, notebookId: element.notebookId)
        return true
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
        notebookId: UUID
    ) {
        let storage = StorageService.shared
        let context = storage.context

        let notebookDescriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId }
        )
        guard let notebook = try? context.fetch(notebookDescriptor).first,
              let parentPage = storage.fetchPage(id: afterPageId) else {
            return
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
            return
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
            source: .typed,
            size: .body,
            attributedTextData: MacRichTextCodec.encode(overflow)
        )
        element.textContent = content
        context.insert(element)
        try? context.save()
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

    private static func snapToBoundary(_ s: String, near index: Int) -> Int {
        let chars = Array(s)
        let safeIdx = min(max(0, index), chars.count)
        let windowStart = max(0, safeIdx - 120)
        if let nl = (windowStart..<safeIdx).reversed().first(where: { chars[$0] == "\n" }) {
            return nl + 1
        }
        if let ws = (windowStart..<safeIdx).reversed().first(where: { chars[$0].isWhitespace }) {
            return ws + 1
        }
        return safeIdx
    }
}

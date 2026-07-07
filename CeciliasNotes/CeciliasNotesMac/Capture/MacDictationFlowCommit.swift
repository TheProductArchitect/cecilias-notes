import AppKit
import Foundation
import SwiftData
import SwiftUI

/// Mac-local dictation commits — mirrors shared `DictationFlowCommit`.
@MainActor
enum MacDictationFlowCommit {
    /// Pick the page + Y anchor for a new transcription block.
    static func resolveTranscriptionAnchor(
        startingPage: Page,
        notebook: Notebook,
        storage: StorageService
    ) -> (page: Page, normalizedY: Double) {
        let pageSize = startingPage.pageSize.pointSize
        var targetPage = startingPage
        var openY = openYOnPage(pageId: startingPage.id, pageSize: pageSize)

        if openY >= 0.5, notebook.autoAddPagesOnScroll {
            let pages = storage.fetchPages(in: notebook)
            if pages.last?.id == startingPage.id,
               let newPage = MacPageEditing.addPage(in: notebook, after: startingPage, storage: storage) {
                targetPage = newPage
                openY = MacDocPageLayout.normalizedTopMargin(pageHeight: newPage.pageSize.pointSize.height)
            }
        }
        return (targetPage, openY)
    }

    static func openYOnPage(pageId: UUID, pageSize: CGSize) -> Double {
        let context = StorageService.shared.context
        let pid = pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let existing = ((try? context.fetch(descriptor)) ?? []).filter { $0.kind != .stroke }
        let topY = MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
        guard let lowestBottom = existing.map({ $0.normalizedY + $0.normalizedHeight }).max() else {
            return topY
        }
        return min(0.88, max(topY, lowestBottom + 0.02))
    }

    @discardableResult
    static func createInitialTextElement(
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize,
        normalizedY: Double? = nil
    ) -> UUID {
        let context = StorageService.shared.context
        let elementId = UUID()
        let marginX = MacDocPageLayout.normalizedHorizontalMargin(pageWidth: pageSize.width)
        let contentWidth = MacDocPageLayout.normalizedContentWidth(pageWidth: pageSize.width)
        let y = normalizedY ?? MacDocPageLayout.normalizedTopMargin(pageHeight: pageSize.height)
        let zIndex = nextZIndex(forPageId: pageId, context: context)
        let element = PageElement(
            id: elementId,
            pageId: pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: marginX,
            normalizedY: y,
            normalizedWidth: contentWidth,
            normalizedHeight: 0.12,
            zIndex: zIndex
        )
        element.textContent = TextContent(text: "", source: .dictated, size: .body)
        context.insert(element)
        try? context.save()
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        return elementId
    }

    /// Streaming path — hops to the next runloop tick so partials arriving
    /// mid view-update never publish synchronously.
    static func updateText(elementId: UUID, text: String) {
        DispatchQueue.main.async {
            applyTextUpdate(elementId: elementId, text: text)
        }
    }

    /// Synchronous core — `stop()` uses this directly so everything after
    /// it (audio placement, reflow) sees the final text and any overflow
    /// split already applied.
    static func applyTextUpdate(elementId: UUID, text: String) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == elementId }
        )
        guard let element = try? context.fetch(descriptor).first,
              let content = element.textContent else { return }
        guard content.text != text else { return }

        content.text = text
        content.updatedAt = Date()
        let attrs = MacRichTextCodec.defaultTypingAttributes(size: content.size)
        let attributed = NSAttributedString(string: text, attributes: attrs)
        content.attributedTextData = MacRichTextCodec.encode(attributed)
        element.updatedAt = Date()

        let pageHeight = StorageService.shared.fetchPage(id: element.pageId)?
            .pageSize.pointSize.height ?? PageSize.a4.pointSize.height
        let measured = ceil(attributed.boundingRect(
            with: CGSize(
                width: max(40, pageSizeContentWidth(for: element)),
                height: .greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        let normH = min(0.88, max(0.08, Double((measured + 8) / pageHeight)))
        if abs(element.normalizedHeight - normH) > 0.005 {
            element.normalizedHeight = normH
        }

        let originY = CGFloat(element.normalizedY) * pageHeight
        if let split = MacTextElementSplitter.splitIfNeeded(
            element: element,
            content: content,
            pageSize: CGSize(width: pageSizeContentWidth(for: element) + 2 * MacDocPageLayout.horizontalMargin, height: pageHeight),
            originY: originY
        ) {
            MacRecordingSession.shared.retargetTranscription(
                to: split.continuationElementId,
                consumedUTF16: split.overflowStartUTF16
            )
        }

        Page.clearInkbookStash(forPageId: element.pageId, context: context)
        try? context.save()
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        NotificationCenter.default.post(
            name: .macLiveTranscriptUpdated,
            object: nil,
            userInfo: [MacTranscriptionKeys.elementId: elementId]
        )
    }

    static func finalizeTextElement(elementId: UUID, text: String) {
        applyTextUpdate(elementId: elementId, text: text)
        let context = StorageService.shared.context
        let eid = elementId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == eid }
        )
        if let pageId = try? context.fetch(descriptor).first?.pageId {
            MacPageElementReflow.packVerticalLayout(pageId: pageId)
        }
    }

    private static func pageSizeContentWidth(for element: PageElement) -> CGFloat {
        let pageWidth = StorageService.shared.fetchPage(id: element.pageId)?
            .pageSize.pointSize.width ?? PageSize.a4.pointSize.width
        return max(40, pageWidth - 2 * MacDocPageLayout.horizontalMargin)
    }

    private static func nextZIndex(forPageId pageId: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.zIndex, order: .reverse)]
        )
        return ((try? context.fetch(descriptor))?.first?.zIndex ?? 0) + 1
    }
}

enum MacTranscriptionKeys {
    static let elementId = "textElementId"
}

extension Notification.Name {
    static let macLiveTranscriptUpdated = Notification.Name("app.ceciliasnotes.mac.liveTranscriptUpdated")
    static let macTranscriptionStarted = Notification.Name("app.ceciliasnotes.mac.transcriptionStarted")
}

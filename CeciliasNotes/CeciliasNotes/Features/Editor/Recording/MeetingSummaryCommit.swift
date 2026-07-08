#if canImport(UIKit)
import Foundation
import SwiftData
import UIKit

/// iPad/iPhone tail of the meeting-assistant flow — the exact
/// experience the Mac ships: when a dictation stops, distill the
/// transcript with on-device Apple Intelligence
/// (`MeetingSummarizer`, shared prompts) and place a SUMMARY block
/// ABOVE the transcript so the page reads summary-first.
///
/// Failure paths all degrade to "just the transcript": no Apple
/// Intelligence → no placeholder; generation fails → placeholder
/// removed. The page never shows an error state.
@MainActor
enum MeetingSummaryCommit {

    static func generateIfWorthwhile(
        transcript: String,
        firstElementId: UUID,
        notebookId: UUID
    ) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MeetingSummarizer.minimumTranscriptCharacters else { return }
        guard MeetingSummarizer.canRun else { return }
        guard let anchor = fetchElement(firstElementId) else { return }

        let placeholder = renderSummary(body: "Summarizing this recording…", pending: true)
        guard let placeholderId = insertSummaryBlock(
            above: anchor,
            notebookId: notebookId,
            attributed: placeholder
        ) else { return }
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)

        Task { @MainActor in
            do {
                let summary = try await MeetingSummarizer.summarize(transcript: trimmed)
                fill(
                    elementId: placeholderId,
                    attributed: renderSummary(body: summary, pending: false),
                    plain: "Summary\n\(summary)"
                )
            } catch {
                removeElement(placeholderId)
            }
            NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        }
    }

    // MARK: - Page mutations

    private static func fetchElement(_ id: UUID) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try? StorageService.shared.context.fetch(descriptor).first
    }

    /// Insert the summary at the transcript's position and nudge the
    /// transcript (and anything below it on the page) down to make
    /// room — the iPad canvas is free-form, so unlike the Mac's
    /// doc-mode reflow we shift explicitly.
    private static func insertSummaryBlock(
        above anchor: PageElement,
        notebookId: UUID,
        attributed: NSAttributedString
    ) -> UUID? {
        let storage = StorageService.shared
        let context = storage.context
        guard let page = storage.fetchPage(id: anchor.pageId) else { return nil }
        let pageSize = page.pageSize.pointSize

        let contentWidth = max(40, CGFloat(anchor.normalizedWidth) * pageSize.width)
        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        let summaryHeight = min(0.5, max(0.05, Double((measured + 10) / pageSize.height)))
        let gap = 0.015
        let shift = summaryHeight + gap

        // Shift the transcript and everything under it. Skip when the
        // page is too full to absorb the shift — a clipped/overlapped
        // page is worse than a missing summary.
        let pid = anchor.pageId
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let onPage = (try? context.fetch(descriptor)) ?? []
        let toShift = onPage.filter { $0.kind != .stroke && $0.normalizedY >= anchor.normalizedY }
        let lowestBottom = toShift.map { $0.normalizedY + $0.normalizedHeight }.max() ?? 0
        guard lowestBottom + shift <= 0.97 else { return nil }

        for element in toShift {
            element.normalizedY += shift
            element.updatedAt = Date()
        }

        let element = PageElement(
            id: UUID(),
            pageId: anchor.pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: anchor.normalizedX,
            normalizedY: anchor.normalizedY - shift,
            normalizedWidth: anchor.normalizedWidth,
            normalizedHeight: summaryHeight,
            zIndex: anchor.zIndex
        )
        element.textContent = TextContent(
            text: attributed.string,
            source: .ai,
            size: .body,
            attributedTextData: try? NSKeyedArchiver.archivedData(
                withRootObject: attributed,
                requiringSecureCoding: true
            )
        )
        context.insert(element)
        Page.clearInkbookStash(forPageId: anchor.pageId, context: context)
        do {
            try context.save()
            return element.id
        } catch {
            return nil
        }
    }

    private static func fill(elementId: UUID, attributed: NSAttributedString, plain: String) {
        guard let element = fetchElement(elementId),
              let content = element.textContent else { return }
        content.text = plain
        content.attributedTextData = try? NSKeyedArchiver.archivedData(
            withRootObject: attributed,
            requiringSecureCoding: true
        )
        content.updatedAt = Date()
        element.updatedAt = Date()

        let storage = StorageService.shared
        if let page = storage.fetchPage(id: element.pageId) {
            let pageSize = page.pageSize.pointSize
            let contentWidth = max(40, CGFloat(element.normalizedWidth) * pageSize.width)
            let measured = ceil(attributed.boundingRect(
                with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            element.normalizedHeight = min(0.6, max(0.05, Double((measured + 10) / pageSize.height)))
        }
        Page.clearInkbookStash(forPageId: element.pageId, context: storage.context)
        try? storage.context.save()
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: element.notebookId)
    }

    private static func removeElement(_ id: UUID) {
        guard let element = fetchElement(id) else { return }
        let context = StorageService.shared.context
        Page.clearInkbookStash(forPageId: element.pageId, context: context)
        context.delete(element)
        try? context.save()
    }

    // MARK: - Rendering

    /// "SUMMARY" eyebrow + body in the shared editorial voice —
    /// byte-for-byte the same treatment the Mac renders.
    private static func renderSummary(body: String, pending: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "SUMMARY\n",
            attributes: [
                .font: NoteTypography.eyebrowFont,
                .foregroundColor: UIColor.secondaryLabel,
                .kern: NoteTypography.eyebrowKern,
                .paragraphStyle: NoteTypography.paragraphStyle(),
            ]
        ))
        var bodyAttributes = RichTextController.defaultAttributes(ink: .label)
        if pending {
            bodyAttributes[.font] = NoteTypography.bodyFont.with(traits: .traitItalic)
            bodyAttributes[.foregroundColor] = UIColor.tertiaryLabel
        }
        out.append(NSAttributedString(string: body, attributes: bodyAttributes))
        return out
    }
}
#endif

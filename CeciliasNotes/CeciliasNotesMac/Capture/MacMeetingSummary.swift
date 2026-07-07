import AppKit
import Foundation
import SwiftData

/// The Mac's meeting-assistant tail: after a live transcription
/// stops, distill the transcript with on-device Apple Intelligence
/// and place the summary ABOVE the transcript, so a notebook page
/// reads summary-first the way meeting notes should.
///
/// Flow (all failure paths degrade to "just the transcript"):
///
///  1. `stopTranscription` calls `generateIfWorthwhile` with the full
///     transcript and the FIRST transcript element (stable across
///     page-overflow splits).
///  2. A "Summary — thinking…" placeholder block is inserted directly
///     above that element and the page re-packs.
///  3. The transcript is summarized off the critical path — chunked
///     map-reduce keeps long meetings inside the on-device model's
///     context window.
///  4. Success replaces the placeholder body; failure removes the
///     placeholder entirely. Either way the page never shows an error
///     state — quiet chrome, per the design language.
@MainActor
enum MacMeetingSummary {

    /// Below this the transcript IS the summary — don't add noise.
    static let minimumTranscriptCharacters = 280

    /// Per-chunk budget for the map phase. Sized against the same
    /// conservative window `AIService.maxPromptCharacters` uses.
    private static let chunkCharacters = 9_000

    static func generateIfWorthwhile(
        transcript: String,
        firstElementId: UUID,
        notebookId: UUID
    ) {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumTranscriptCharacters else { return }
        guard AIService.shared.canRun else { return }
        guard let anchor = fetchElement(firstElementId) else { return }

        guard let placeholderId = insertSummaryBlock(
            above: anchor,
            notebookId: notebookId,
            attributed: renderSummary(body: "Summarizing this recording…", pending: true)
        ) else { return }
        MacPageElementReflow.packVerticalLayout(pageId: anchor.pageId)
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)

        let pageId = anchor.pageId
        Task { @MainActor in
            do {
                let summary = try await summarize(transcript: trimmed)
                fill(elementId: placeholderId, attributed: renderSummary(body: summary, pending: false), plain: "Summary\n\(summary)")
            } catch {
                removeElement(placeholderId)
            }
            MacPageElementReflow.packVerticalLayout(pageId: pageId)
            NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        }
    }

    // MARK: - Summarization (map-reduce over the on-device model)

    private static let mapSystemPrompt = """
        You condense a segment of a meeting transcript. Extract only what matters: \
        topics discussed, decisions made, action items with owners, open questions, \
        and key facts or numbers. Write terse bullet lines, no preamble.
        """

    private static let reduceSystemPrompt = """
        You write the final summary of a meeting from condensed notes. Structure it as: \
        a 1-3 sentence overview paragraph, then a short list of key points, then \
        "Decisions:" and "Action items:" lines when any exist (omit the label when \
        there are none). Plain text only — no markdown symbols like # or *. Use \
        "- " for list items. Be concise and specific; never invent details.
        """

    static func summarize(transcript: String) async throws -> String {
        let provider = AIService.shared.provider

        if transcript.count <= chunkCharacters {
            return try await provider.complete(
                systemPrompt: reduceSystemPrompt,
                userPrompt: transcript,
                maxTokens: 700,
                temperature: 0.3
            )
        }

        // Map: condense each slice independently.
        var partials: [String] = []
        var start = transcript.startIndex
        while start < transcript.endIndex {
            let end = transcript.index(
                start, offsetBy: chunkCharacters, limitedBy: transcript.endIndex
            ) ?? transcript.endIndex
            let chunk = String(transcript[start..<end])
            let partial = try await provider.complete(
                systemPrompt: mapSystemPrompt,
                userPrompt: chunk,
                maxTokens: 400,
                temperature: 0.3
            )
            partials.append(partial)
            start = end
        }

        // Reduce: fold the condensed slices into one summary. If even
        // the joined partials exceed the window (multi-hour meeting),
        // recurse — each round shrinks the text by roughly 10×.
        let joined = partials.joined(separator: "\n")
        if joined.count > chunkCharacters {
            return try await summarize(transcript: joined)
        }
        return try await provider.complete(
            systemPrompt: reduceSystemPrompt,
            userPrompt: joined,
            maxTokens: 700,
            temperature: 0.3
        )
    }

    // MARK: - Page mutations

    private static func fetchElement(_ id: UUID) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try? StorageService.shared.context.fetch(descriptor).first
    }

    /// Insert the summary block directly above `anchor` (fractionally
    /// smaller Y so the reflow pass orders it first).
    private static func insertSummaryBlock(
        above anchor: PageElement,
        notebookId: UUID,
        attributed: NSAttributedString
    ) -> UUID? {
        let context = StorageService.shared.context
        let pageHeight = StorageService.shared.fetchPage(id: anchor.pageId)?
            .pageSize.pointSize.height ?? PageSize.a4.pointSize.height
        let measuredHeight = estimateNormalizedHeight(attributed, anchor: anchor, pageHeight: pageHeight)

        let element = PageElement(
            id: UUID(),
            pageId: anchor.pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: anchor.normalizedX,
            normalizedY: max(0, anchor.normalizedY - 0.001),
            normalizedWidth: anchor.normalizedWidth,
            normalizedHeight: measuredHeight,
            zIndex: anchor.zIndex
        )
        element.textContent = TextContent(
            text: attributed.string,
            source: .ai,
            size: .body,
            attributedTextData: MacRichTextCodec.encode(attributed)
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
        content.attributedTextData = MacRichTextCodec.encode(attributed)
        content.updatedAt = Date()
        element.updatedAt = Date()
        let pageHeight = StorageService.shared.fetchPage(id: element.pageId)?
            .pageSize.pointSize.height ?? PageSize.a4.pointSize.height
        element.normalizedHeight = estimateNormalizedHeight(attributed, anchor: element, pageHeight: pageHeight)
        Page.clearInkbookStash(forPageId: element.pageId, context: StorageService.shared.context)
        try? StorageService.shared.context.save()
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: element.notebookId)
    }

    private static func removeElement(_ id: UUID) {
        guard let element = fetchElement(id) else { return }
        let context = StorageService.shared.context
        Page.clearInkbookStash(forPageId: element.pageId, context: context)
        context.delete(element)
        try? context.save()
    }

    private static func estimateNormalizedHeight(
        _ attributed: NSAttributedString,
        anchor: PageElement,
        pageHeight: CGFloat
    ) -> Double {
        let pageWidth = StorageService.shared.fetchPage(id: anchor.pageId)?
            .pageSize.pointSize.width ?? PageSize.a4.pointSize.width
        let contentWidth = max(40, CGFloat(anchor.normalizedWidth) * pageWidth)
        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        return min(0.88, max(0.05, Double((measured + 10) / pageHeight)))
    }

    // MARK: - Rendering

    /// "SUMMARY" eyebrow + body, in the editorial voice: small
    /// tracked-uppercase label, then regular body text.
    private static func renderSummary(body: String, pending: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(
            string: "SUMMARY\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 1.6,
            ]
        ))
        var bodyAttributes = MacRichTextCodec.defaultTypingAttributes(size: .body)
        if pending {
            bodyAttributes[.font] = NSFont.systemFont(ofSize: 15).withItalics()
            bodyAttributes[.foregroundColor] = NSColor.tertiaryLabelColor
        }
        out.append(NSAttributedString(string: body, attributes: bodyAttributes))
        return out
    }
}

private extension NSFont {
    func withItalics() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}

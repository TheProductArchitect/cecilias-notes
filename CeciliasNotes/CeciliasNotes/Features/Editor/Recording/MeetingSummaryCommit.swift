#if canImport(UIKit)
import Foundation
import SwiftData
import UIKit

/// iPad/iPhone tail of the meeting-assistant flow: when a dictation
/// stops, distill the transcript with on-device Apple Intelligence
/// (`MeetingSummarizer`, shared prompts with the Mac) and place the
/// summary at the TOP of the transcript block — prepended INTO the
/// same text element, so the page reads summary-first.
///
/// Prepending (rather than inserting a separate element above) is
/// deliberate: the iPad canvas is free-form, and a separate element
/// had to guess at pixel geometry — on real pages it overlapped ink
/// and neighbouring blocks. Inside the block there is nothing to
/// collide with: the summary scrolls, moves, and exports with its
/// transcript.
///
/// Failure paths all degrade to "just the transcript": no Apple
/// Intelligence → nothing happens; generation fails → nothing
/// happens. The page never shows an error or placeholder state.
@MainActor
enum MeetingSummaryCommit {

    static func generateIfWorthwhile(
        transcript: String,
        firstElementId: UUID,
        notebookId: UUID
    ) {
        guard DictationSummaryPreference.isEnabled else { return }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MeetingSummarizer.minimumTranscriptCharacters else { return }
        guard MeetingSummarizer.canRun else { return }

        Task { @MainActor in
            guard let summary = try? await MeetingSummarizer.summarize(transcript: trimmed) else { return }
            prependSummary(summary, toElementId: firstElementId, notebookId: notebookId)
        }
    }

    // MARK: - Prepend into the transcript block

    /// Internal (not private) so the unit suite can drive the commit
    /// tail directly — `MeetingSummarizer.canRun` is always false in
    /// simulators, so without this seam the entire post-summary write
    /// path (archiving, geometry, save, notifications) ships untested.
    static func prependSummary(
        _ summary: String,
        toElementId elementId: UUID,
        notebookId: UUID
    ) {
        guard let element = fetchElement(elementId),
              let content = element.textContent else { return }

        // Existing transcript content, styled — dictation writes
        // plain text, so fall back to the shared editorial defaults.
        let existing: NSAttributedString
        if let data = content.attributedTextData, !data.isEmpty,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(
               ofClass: NSAttributedString.self, from: data
           ) {
            existing = decoded
        } else {
            existing = NSAttributedString(
                string: content.text,
                attributes: RichTextController.defaultAttributes(ink: .label)
            )
        }

        let composed = NSMutableAttributedString()
        composed.append(NSAttributedString(
            string: "SUMMARY\n",
            attributes: [
                .font: NoteTypography.eyebrowFont,
                .foregroundColor: UIColor.secondaryLabel,
                .kern: NoteTypography.eyebrowKern,
                .paragraphStyle: NoteTypography.paragraphStyle(),
            ]
        ))
        composed.append(NSAttributedString(
            string: summary + "\n\n",
            attributes: RichTextController.defaultAttributes(ink: .label)
        ))
        composed.append(existing)

        content.text = "Summary\n\(summary)\n\n\(content.text)"
        content.attributedTextData = try? NSKeyedArchiver.archivedData(
            withRootObject: composed,
            requiringSecureCoding: true
        )
        content.updatedAt = Date()
        element.updatedAt = Date()

        // Grow the element for the added lines so the block doesn't
        // clip until the next edit re-measures it. Every input is
        // guarded: an element sitting below 92% page height makes
        // `0.92 - normalizedY` NEGATIVE, and a zero page height makes
        // `normalized` infinite — either writes poisoned geometry
        // that every later render of this element inherits.
        let storage = StorageService.shared
        if let page = storage.fetchPage(id: element.pageId) {
            let pageSize = page.pageSize.pointSize
            if pageSize.height > 0 {
                let contentWidth = max(40, CGFloat(element.normalizedWidth) * pageSize.width)
                let measured = ceil(composed.boundingRect(
                    with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    context: nil
                ).height)
                let normalized = Double((measured + 10) / pageSize.height)
                let cap = 0.92 - element.normalizedY
                if normalized.isFinite, cap > element.normalizedHeight {
                    element.normalizedHeight = min(cap, max(element.normalizedHeight, normalized))
                }
            }
        }

        Page.clearInkbookStash(forPageId: element.pageId, context: storage.context)
        try? storage.context.save()
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: notebookId)
    }

    private static func fetchElement(_ id: UUID) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try? StorageService.shared.context.fetch(descriptor).first
    }
}
#endif

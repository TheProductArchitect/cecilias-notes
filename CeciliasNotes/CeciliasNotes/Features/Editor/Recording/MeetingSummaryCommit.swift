#if canImport(UIKit)
import Foundation
import SwiftData
import UIKit

/// iPad/iPhone tail of the meeting-assistant flow: when a dictation
/// stops, distill the transcript with on-device Apple Intelligence
/// (`MeetingSummarizer`, shared prompts with the Mac) and place the
/// summary as its OWN text element at the top of the dictation
/// cluster, shifting the audio pill and transcript down beneath it —
/// so every device reads **summary → audio pill → transcript**.
///
/// This runs on a freshly-created dictation page whose only elements
/// are the pill and the transcript, so shifting that pair down can't
/// collide with unrelated content. Every geometry write is clamped
/// finite and inside [0, 0.92] — the earlier "poisoned geometry"
/// crash came from writing a negative/infinite `normalizedHeight`.
///
/// Failure paths all degrade to "just the transcript": no Apple
/// Intelligence → nothing happens; generation fails → nothing
/// happens. The page never shows an error or placeholder state.
@MainActor
enum MeetingSummaryCommit {

    /// Highest normalised Y a block's top may sit at (leaves a bottom
    /// margin). Shared with the geometry clamps below.
    private static let bottomCap: Double = 0.92

    static func generateIfWorthwhile(
        transcript: String,
        firstElementId: UUID,
        notebookId: UUID
    ) {
        guard DictationSummaryPreference.isEnabled else {
            #if DEBUG
            dlog("[Summary] skipped — auto-summary preference OFF")
            #endif
            return
        }
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= MeetingSummarizer.minimumTranscriptCharacters else {
            #if DEBUG
            dlog("[Summary] skipped — transcript \(trimmed.count) chars < minimum \(MeetingSummarizer.minimumTranscriptCharacters); short transcripts are their own summary")
            #endif
            return
        }
        guard MeetingSummarizer.canRun else {
            #if DEBUG
            dlog("[Summary] skipped — Apple Intelligence unavailable or user opted out")
            #endif
            return
        }

        Task { @MainActor in
            do {
                let summary = try await MeetingSummarizer.summarize(transcript: trimmed)
                #if DEBUG
                dlog("[Summary] generated \(summary.count) chars from \(trimmed.count)-char transcript")
                #endif
                commitSummary(summary, transcriptElementId: firstElementId, notebookId: notebookId)
            } catch {
                #if DEBUG
                dlog("[Summary] generation failed: \(error)")
                #endif
            }
        }
    }

    // MARK: - Summary as a separate top element

    /// Internal (not private) so the unit suite can drive the commit
    /// tail directly — `MeetingSummarizer.canRun` is always false in
    /// simulators, so without this seam the entire post-summary write
    /// path (archiving, geometry, save, notifications) ships untested.
    static func commitSummary(
        _ summary: String,
        transcriptElementId elementId: UUID,
        notebookId: UUID
    ) {
        guard let transcript = fetchElement(elementId),
              transcript.textContent != nil else { return }
        let storage = StorageService.shared
        let context = storage.context
        let pageId = transcript.pageId
        guard let page = storage.fetchPage(id: pageId) else { return }
        let pageSize = page.pageSize.pointSize
        guard pageSize.height > 0, pageSize.width > 0 else { return }

        // Build the summary block: SUMMARY eyebrow + body.
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
            string: summary,
            attributes: RichTextController.defaultAttributes(ink: .label)
        ))

        // Measure the summary's height — guarded against non-finite.
        let contentWidth = max(40, CGFloat(transcript.normalizedWidth) * pageSize.width)
        let measured = ceil(composed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)
        guard measured.isFinite, measured > 0 else { return }
        let summaryHeight = min(0.4, max(0.04, Double((measured + 12) / pageSize.height)))

        // The audio pill (created at stop, sitting just above the
        // transcript). May be absent if the user turned audio-clip
        // saving off — then the order is simply summary → transcript.
        let pill = fetchAudioElement(pageId: pageId)

        // Top of the existing dictation cluster.
        let clusterTop = min(pill?.normalizedY ?? transcript.normalizedY, transcript.normalizedY)
        let summaryY = clamp(min(clusterTop, bottomCap - summaryHeight))

        // Shift the pill + transcript down so the summary owns the top.
        let shift = summaryHeight + 0.012
        for el in [pill, transcript].compactMap({ $0 }) {
            let maxY = max(0, bottomCap - el.normalizedHeight)
            let newY = clamp(min(maxY, el.normalizedY + shift))
            el.normalizedY = newY
            el.updatedAt = Date()
        }

        // Create the summary element above them.
        let summaryEl = PageElement(
            pageId: pageId,
            notebookId: notebookId,
            kind: .text,
            normalizedX: transcript.normalizedX,
            normalizedY: summaryY,
            normalizedWidth: transcript.normalizedWidth,
            normalizedHeight: summaryHeight,
            zIndex: nextZIndex(pageId: pageId, context: context)
        )
        let sc = TextContent(text: "Summary\n\(summary)", source: .ai, size: .body)
        sc.attributedTextData = try? NSKeyedArchiver.archivedData(
            withRootObject: composed, requiringSecureCoding: true
        )
        summaryEl.textContent = sc
        context.insert(summaryEl)

        Page.clearInkbookStash(forPageId: pageId, context: context)
        try? context.save()
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
        // The pill moved — nudge the audio overlay to re-fetch.
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: notebookId)
    }

    // MARK: - Helpers

    private static func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0.01 }
        return min(bottomCap, max(0, v))
    }

    private static func fetchElement(_ id: UUID) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.id == id }
        )
        return try? StorageService.shared.context.fetch(descriptor).first
    }

    private static func fetchAudioElement(pageId: UUID) -> PageElement? {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil }
        )
        let elements = (try? StorageService.shared.context.fetch(descriptor)) ?? []
        return elements.first { $0.kind == .audio }
    }

    private static func nextZIndex(pageId: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil }
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return (elements.map(\.zIndex).max() ?? 0) + 1
    }
}
#endif

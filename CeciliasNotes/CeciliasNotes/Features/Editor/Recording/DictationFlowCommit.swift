import Foundation
import SwiftData
import SwiftUI
import UIKit

/// SwiftData commit helpers specific to the Dictation flow. The
/// session (`RecordingSession`) holds the high-level state machine;
/// these are the per-step writes that mutate `PageElement` /
/// `TextContent` / `AudioContent` rows.
///
/// Three writes happen during a dictation:
///   1. `createInitialTextElement` — on start, after the editor
///      created a new Page. Seeds the transcript element.
///   2. `updateText` — live, every transcript tick from the
///      recorder's `$liveTranscript` publisher.
///   3. `createContinuationPage` — when the live transcript on the
///      current page exceeds the heuristic byte budget at a
///      sentence boundary.
///
/// One write happens on stop:
///   4. `finalizeDictation` — adopts the audio file into the
///      unified audio/ tree, creates the AudioContent + audio
///      strip element above the first transcript text, links them
///      via `AudioContent.anchorText`.
@MainActor
enum DictationFlowCommit {

    // MARK: - Layout constants

    /// Width of the transcript text element (≈ 80% of page width).
    private static let textElementWidth: Double = 0.8
    /// Inset from the page top — leaves space for the audio strip
    /// that lands above on stop. 8pt gap baked in.
    private static let textElementTopInset: Double = 0.08
    /// Initial transcript height — auto-grows as text streams in
    /// (the editor's text view doesn't honour the stored normalised
    /// height for in-flight elements; the cap matters only when
    /// the element is later edited via the cursor tool).
    private static let textElementInitialHeight: Double = 0.5

    /// Audio strip placement above the first transcript text on
    /// stop. Sits at the top of the page with a small breathing
    /// margin; the text element below it stays at `textElementTopInset`
    /// so the strip + gap fits naturally above.
    private static let stripTopInset: Double = 0.02
    /// Vertical gap between the audio strip and the text element.
    private static let stripGap: Double = 0.01

    // MARK: - Step 1: initial text element

    /// Seed an empty TextContent + PageElement at the top of a
    /// freshly-created dictation page. Returns the PageElement id
    /// so the recording session can update its text as transcript
    /// streams in.
    @discardableResult
    static func createInitialTextElement(
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize
    ) -> UUID {
        // Pre-allocate the elementId synchronously and DEFER every
        // SwiftData operation (init + relationship attach + insert +
        // save) to a Task hop. Device logs across 2026-06-22 showed
        // that even `context.insert(element)` can block on the main
        // mainContext while CloudKit's WAL checkpoint + Core Data
        // import holds an internal SwiftData metadata lock — the
        // entire mainContext is unreachable on the synchronous
        // frame. Pre-allocating the UUID lets the calling
        // `RecordingSession.startDictation` continue without
        // touching SwiftData here at all; the row materialises
        // asynchronously once the metadata lock clears.
        //
        // updateText already handles the "row not yet materialised"
        // case via a no-op + redrive on the next partial-result
        // tick (see `updateText` below — when the fetch fails it
        // attempts a lazy create from the cached metadata, then
        // returns). The lazy create + the deferred create race
        // benignly through `id`: whichever lands first wins, the
        // second silently no-ops because the row already exists.
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=enter")
        #endif
        let elementId = UUID()
        Self.pendingPlaceholderMetadata[elementId] = PendingPlaceholder(
            pageId: pageId,
            notebookId: notebookId,
            pageSize: pageSize
        )
        Task { @MainActor in
            #if DEBUG
            dlog("[Dictation] createInitialTextElement phase=deferredEntry elementId=\(elementId)")
            #endif
            Self.materializePlaceholderIfNeeded(elementId: elementId)
        }
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=returnedImmediately elementId=\(elementId)")
        #endif
        return elementId
    }

    /// Metadata captured at `createInitialTextElement` call time so
    /// the deferred materialisation (and the updateText lazy
    /// fallback) has everything it needs to insert the row without
    /// re-resolving Notebook / Page references.
    private struct PendingPlaceholder {
        let pageId: UUID
        let notebookId: UUID
        let pageSize: CGSize
    }
    nonisolated(unsafe) private static var pendingPlaceholderMetadata: [UUID: PendingPlaceholder] = [:]

    /// Insert the PageElement + TextContent row described by the
    /// pending metadata. Idempotent: if the row already exists
    /// (because updateText's lazy create won the race, or because
    /// a previous materialisation succeeded), this is a no-op.
    @MainActor
    fileprivate static func materializePlaceholderIfNeeded(elementId: UUID) {
        guard let meta = pendingPlaceholderMetadata[elementId] else {
            // Already materialised; nothing to do.
            return
        }
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.id == elementId }
        )
        if let _ = try? context.fetch(descriptor).first {
            // Row already in the context — possibly the updateText
            // lazy path beat us here. Drop the pending metadata so
            // a future call can't re-insert.
            pendingPlaceholderMetadata.removeValue(forKey: elementId)
            return
        }
        let element = PageElement(
            id: elementId,
            pageId: meta.pageId,
            notebookId: meta.notebookId,
            kind: .text,
            normalizedX: (1 - textElementWidth) / 2,
            normalizedY: textElementTopInset,
            normalizedWidth: textElementWidth,
            normalizedHeight: textElementInitialHeight,
            zIndex: 1
        )
        let content = TextContent(
            text: "",
            source: .dictated,
            size: .body
        )
        element.textContent = content
        context.insert(element)
        do {
            try context.save()
            pendingPlaceholderMetadata.removeValue(forKey: elementId)
            #if DEBUG
            dlog("[Dictation] materializePlaceholder OK elementId=\(elementId)")
            #endif
        } catch {
            #if DEBUG
            dlog("[Dictation] materializePlaceholder SAVE FAILED elementId=\(elementId): \(error)")
            #endif
        }
    }

    // MARK: - Step 2: live text update

    /// Write the current transcript into the element's TextContent.
    /// Cheap — no row creation, just a field mutation + save.
    /// Throttling is handled upstream (the recorder publishes at
    /// its own cadence; SwiftData coalesces same-runloop writes).
    static func updateText(elementId: UUID, text: String) {
        // Defer to the next runloop tick. The recogniser's
        // partial-result callback lands inside RecordingSession's
        // Combine sink on the main queue, which fires *during* the
        // SwiftUI view-update transaction triggered by the
        // previous partial's @Bindable propagation. Writing
        // SwiftData synchronously here re-entrantly triggers
        // another @Published mutation, which produces the
        // "Publishing changes from within view updates is not
        // allowed" warning + cascading view-update churn. One
        // runloop tick breaks the synchronous chain so each
        // partial lands cleanly.
        DispatchQueue.main.async {
            let context = StorageService.shared.context
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate { $0.id == elementId }
            )
            // Try to find the row; if the createInitialTextElement
            // deferred materialisation hasn't landed yet (CloudKit
            // contention can hold it off for hundreds of ms), run
            // it now from the cached metadata so this tick has
            // something to write into. Without this lazy fallback
            // every partial that arrives before the deferred Task
            // runs is silently dropped.
            if (try? context.fetch(descriptor).first) == nil {
                materializePlaceholderIfNeeded(elementId: elementId)
            }
            guard let element = try? context.fetch(descriptor).first,
                  let content = element.textContent
            else {
                #if DEBUG
                dlog("[Dictation] updateText DROP — element/content fetch failed (elementId=\(elementId))")
                #endif
                return
            }
            if content.text != text {
                content.text = text
                content.updatedAt = Date()
                element.updatedAt = Date()
                // Invalidate the inkbook stash on this page so the
                // mirror reflects dictation appends rather than the
                // original AI-written blocks. Funnels dictation
                // through the same exporter path as typed edits.
                Page.clearInkbookStash(
                    forPageId: element.pageId,
                    context: context
                )
                do {
                    try context.save()
                    #if DEBUG
                    dlog("[Dictation] updateText OK — \(text.count) chars saved to elementId=\(elementId)")
                    #endif
                } catch {
                    #if DEBUG
                    dlog("[Dictation] updateText SAVE FAILED: \(error)")
                    #endif
                }
            }
        }
    }

    // MARK: - Step 3: continuation page

    /// Create a new page after the given page and seed it with a
    /// TextContent containing `initialText`. The new TextContent
    /// references `anchorAudioId` so the (eventually-committed)
    /// AudioContent can resolve all its continuation spans on
    /// playback.
    @discardableResult
    static func createContinuationPage(
        afterPageId: UUID,
        notebookId: UUID,
        anchorAudioId: UUID,
        initialText: String
    ) -> (pageId: UUID, textElementId: UUID)? {
        let storage = StorageService.shared
        let context = storage.context

        let notebookDescriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId }
        )
        guard let notebook = try? context.fetch(notebookDescriptor).first,
              let parentPage = storage.fetchPage(id: afterPageId) else {
            return nil
        }

        guard let newPage = try? storage.createPage(
            in: notebook,
            after: parentPage.pageNumber,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        ) else {
            return nil
        }

        let elementId = UUID()
        let element = PageElement(
            id: elementId,
            pageId: newPage.id,
            notebookId: notebookId,
            kind: .text,
            normalizedX: (1 - textElementWidth) / 2,
            normalizedY: textElementTopInset,
            normalizedWidth: textElementWidth,
            normalizedHeight: textElementInitialHeight,
            zIndex: 1
        )
        let content = TextContent(
            text: initialText,
            source: .dictated,
            size: .body,
            anchorAudioId: anchorAudioId
        )
        element.textContent = content
        context.insert(element)
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[Dictation] createContinuationPage SAVE FAILED pageId=\(newPage.id): \(error)")
            #endif
        }

        return (pageId: newPage.id, textElementId: elementId)
    }

    // MARK: - Step 4: finalize on stop

    /// Final stop-time write. Creates the AudioContent + audio
    /// strip element above the first transcript text on the
    /// original dictation page, links AudioContent.anchorText →
    /// first TextContent (the architecture's paired-block design
    /// per §9), and posts the audioElementsChanged notification so
    /// overlays refetch.
    static func finalizeDictation(
        contentId: UUID,
        originalPageId: UUID,
        notebookId: UUID,
        textElementIds: [UUID],
        transcript: String,
        durationSeconds: Double
    ) {
        guard let firstTextElementId = textElementIds.first else { return }
        let context = StorageService.shared.context

        // Look up the first transcript element so the strip can
        // sit immediately above it (paired-block layout). If the
        // user has already moved or deleted it, fall back to the
        // top-of-page default placement.
        let firstElement: PageElement? = {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate { $0.id == firstTextElementId }
            )
            return try? context.fetch(descriptor).first
        }()

        let pageSize = pageSizePoints(forPageId: originalPageId)
        let stripHeight = AudioElementCommit.defaultStripHeight(
            forPagePoints: Double(pageSize.height)
        )

        let stripX: Double
        let stripY: Double
        let stripWidth: Double
        if let firstElement {
            stripX = firstElement.normalizedX
            stripY = max(stripTopInset, firstElement.normalizedY - stripHeight - stripGap)
            stripWidth = firstElement.normalizedWidth
        } else {
            stripX = (1 - textElementWidth) / 2
            stripY = stripTopInset
            stripWidth = textElementWidth
        }

        // Create the audio strip element with its own
        // PageElement(.audio) + AudioContent. Link the content's
        // anchorText to the first TextContent so playback can
        // resolve back to the on-page transcript.
        let stripElement = PageElement(
            id: UUID(),
            pageId: originalPageId,
            notebookId: notebookId,
            kind: .audio,
            normalizedX: stripX,
            normalizedY: stripY,
            normalizedWidth: stripWidth,
            normalizedHeight: stripHeight,
            zIndex: nextZIndex(forPageId: originalPageId, context: context)
        )
        let audioContent = AudioContent(
            id: contentId,
            filename: "\(contentId.uuidString).m4a",
            durationSeconds: durationSeconds,
            transcript: transcript
        )
        if let firstElement, let firstText = firstElement.textContent {
            audioContent.anchorText = firstText
        }
        stripElement.audioContent = audioContent
        context.insert(stripElement)
        do {
            try context.save()
        } catch {
            // Critical: this is the stop-time write that binds the
            // on-disk .m4a to a queryable AudioContent row. Without
            // it the audio file is orphaned — present in
            // MediaStorage.audio/ but unreachable from any overlay,
            // and the refinement-pass transcript update will fail
            // its row lookup. Log loudly so a "my recording
            // disappeared" report can be triaged.
            #if DEBUG
            dlog("[Dictation] finalizeDictation SAVE FAILED contentId=\(contentId) audioId=\(audioContent.id): \(error)")
            #endif
        }

        // Populate `audioData` from the on-disk recording so the
        // bytes ride CloudKit alongside the row. Done as a follow-up
        // task to avoid blocking finalize on a multi-MB read for
        // long lectures; the row already exists, this just attaches
        // the bytes once the file system has caught up.
        let audioId = audioContent.id
        Task.detached(priority: .utility) {
            let url = MediaStorage.url(for: .audio, id: audioId)
            guard let data = try? Data(contentsOf: url) else { return }
            await MainActor.run {
                let ctx = StorageService.shared.context
                let descriptor = FetchDescriptor<AudioContent>(
                    predicate: #Predicate<AudioContent> { $0.id == audioId }
                )
                if let row = (try? ctx.fetch(descriptor))?.first {
                    row.audioData = data
                    row.updatedAt = Date()
                    do {
                        try ctx.save()
                    } catch {
                        #if DEBUG
                        dlog("[Dictation] audio bytes backfill SAVE FAILED audioId=\(audioId): \(error)")
                        #endif
                    }
                }
            }
        }

        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }

    // MARK: - Helpers

    private static func nextZIndex(forPageId pageId: UUID, context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pageId && $0.deletedAt == nil
            },
            sortBy: [SortDescriptor(\.zIndex, order: .reverse)]
        )
        let elements = (try? context.fetch(descriptor)) ?? []
        return (elements.first?.zIndex ?? 0) + 1
    }

    private static func pageSizePoints(forPageId pageId: UUID) -> CGSize {
        guard let page = StorageService.shared.fetchPage(id: pageId) else {
            return CGSize(width: 595, height: 842)  // A4 fallback
        }
        return page.pageSize.pointSize
    }
}

import Foundation
import SwiftData
import SwiftUI

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
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=enter")
        #endif
        let t0 = CFAbsoluteTimeGetCurrent()
        let context = StorageService.shared.context
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=ctxResolved dt=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
        #endif
        let elementId = UUID()
        let element = PageElement(
            id: elementId,
            pageId: pageId,
            notebookId: notebookId,
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
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=preInsert dt=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
        #endif
        context.insert(element)
        #if DEBUG
        dlog("[Dictation] createInitialTextElement phase=postInsert dt=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
        #endif
        do {
            try context.save()
            #if DEBUG
            dlog("[Dictation] createInitialTextElement phase=postSave dt=\(String(format: "%.3f", CFAbsoluteTimeGetCurrent() - t0))s")
            #endif
        } catch {
            // The dictation surface depends on this row landing —
            // if the initial transcript element doesn't persist,
            // every subsequent partial-result tick has nothing to
            // mutate and the user's words disappear into the void.
            // Swallowed here historically; log so a freeze /
            // missing-transcript report can be triaged from the
            // device log without guessing.
            #if DEBUG
            dlog("[Dictation] createInitialTextElement SAVE FAILED elementId=\(elementId): \(error)")
            #endif
        }
        return elementId
    }

    // MARK: - Step 1b: live recording pill (created at START)

    /// Create the audio pill at dictation START — above the transcript
    /// element — so the user sees the recording is live (pulsing dot +
    /// timer) the moment they begin. `finalizeDictation` promotes THIS
    /// pill on stop (attaches the file, duration, transcript) rather
    /// than creating a second one. Returns the pill's PageElement id.
    @discardableResult
    static func createRecordingPill(
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize,
        contentId: UUID
    ) -> UUID {
        AudioElementCommit.createRecordingPlaceholder(
            contentId: contentId,
            pageId: pageId,
            notebookId: notebookId,
            pageSize: pageSize,
            normalizedX: (1 - textElementWidth) / 2,
            normalizedY: stripTopInset,
            normalizedWidth: textElementWidth
        )
    }

    // MARK: - Step 2: live text update

    /// Save throttle for live dictation. The recogniser delivers
    /// partials 2–5×/second; a `context.save()` for each one kept
    /// the main thread saturated for the whole recording (every
    /// save also fires `NSPersistentStoreRemoteChange`, which
    /// reschedules the hygiene sweep, which fetches whole tables —
    /// compounding stalls). The property write below still happens
    /// per partial — SwiftUI observation is driven by the in-memory
    /// mutation, so the on-page text stays live — but the durable
    /// save + stash invalidation run at most once per second, plus
    /// a trailing pass so the final partial always lands. Stop-time
    /// commits (`finalizeDictation`) save unconditionally.
    private static var lastDictationSaveAt: Date = .distantPast
    private static var trailingDictationSave: Task<Void, Never>?
    private static let dictationSaveInterval: TimeInterval = 1.0

    private static func throttledDictationSave(pageId: UUID) {
        let context = StorageService.shared.context
        let now = Date()
        if now.timeIntervalSince(lastDictationSaveAt) >= dictationSaveInterval {
            trailingDictationSave?.cancel()
            trailingDictationSave = nil
            lastDictationSaveAt = now
            Page.clearInkbookStash(forPageId: pageId, context: context)
            try? context.save()
        } else if trailingDictationSave == nil {
            trailingDictationSave = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_100_000_000)
                guard !Task.isCancelled else { return }
                trailingDictationSave = nil
                lastDictationSaveAt = Date()
                Page.clearInkbookStash(
                    forPageId: pageId,
                    context: StorageService.shared.context
                )
                try? StorageService.shared.context.save()
            }
        }
    }

    /// Write the current transcript into the element's TextContent.
    /// The field mutation is per-partial (drives the live UI); the
    /// durable save is throttled — see `throttledDictationSave`.
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
                // Durable save + inkbook-stash invalidation are
                // throttled to once per second — the in-memory
                // mutation above already drives the live UI.
                throttledDictationSave(pageId: element.pageId)
                #if DEBUG
                dlog("[Dictation] updateText OK — \(text.count) chars applied to elementId=\(elementId)")
                #endif
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

    /// Final stop-time write. PROMOTES the live recording pill created
    /// at start (`createRecordingPill`, same `contentId`) to its ready
    /// state — sets duration + transcript, repositions it tight above
    /// the first transcript element, and links AudioContent.anchorText
    /// → first TextContent (paired-block design §9). Falls back to
    /// creating a fresh strip only if the user deleted the pill
    /// mid-dictation. Posts audioElementsChanged so overlays refetch.
    static func finalizeDictation(
        audioElementId: UUID,
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

        // Promote the live pill created at start (its AudioContent
        // already carries `contentId`). Only fall back to a fresh
        // element if the pill was deleted mid-dictation.
        let existingPill: PageElement? = {
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.id == audioElementId && $0.deletedAt == nil
                }
            )
            return try? context.fetch(descriptor).first
        }()

        let audioContent: AudioContent
        if let pill = existingPill, let content = pill.audioContent {
            pill.normalizedX = stripX
            pill.normalizedY = stripY
            pill.normalizedWidth = stripWidth
            pill.normalizedHeight = stripHeight
            pill.updatedAt = Date()
            content.durationSeconds = durationSeconds
            content.transcript = transcript
            content.updatedAt = Date()
            audioContent = content
        } else {
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
            let content = AudioContent(
                id: contentId,
                filename: "\(contentId.uuidString).m4a",
                durationSeconds: durationSeconds,
                transcript: transcript
            )
            stripElement.audioContent = content
            context.insert(stripElement)
            audioContent = content
        }
        if let firstElement, let firstText = firstElement.textContent {
            audioContent.anchorText = firstText
        }
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

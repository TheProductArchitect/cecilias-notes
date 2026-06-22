import Foundation
import SwiftData
import UIKit

/// Single commit path for new audio elements. Both the short-note
/// recording flow (`EditorViewModel.stopRecording`) and the lecture
/// recording flow (`EditorViewModel.endLectureMode`) funnel through
/// here so the SwiftData mutation + notification post are owned in
/// one place.
///
/// The caller writes the audio bytes to disk first (either by
/// recording directly to `MediaStorage.url(for: .audio, id:)` or by
/// adopting via `MediaStorage.adoptAudio(at:id:)`), then hands the
/// `(id, duration, transcript)` to this helper.
@MainActor
enum AudioElementCommit {

    /// Default placement for newly-committed audio strips. Top-left
    /// of the page with a slight inset; resizable from the strip
    /// itself in cursor mode.
    private static let defaultNormalizedX: Double = 0.05
    private static let defaultNormalizedY: Double = 0.05
    private static let defaultNormalizedWidth: Double = 0.5
    /// Height in normalised coords — derived from the strip's
    /// 50pt natural height against the page's height. Computed at
    /// commit time so the stored value matches the visible strip
    /// when rendered.
    private static func normalizedHeight(for pageHeightPoints: Double) -> Double {
        guard pageHeightPoints > 0 else { return 0.05 }
        return max(0.04, 50.0 / pageHeightPoints)
    }

    /// Create + persist a `PageElement(kind: .audio)` + `AudioContent`
    /// for an existing audio file on disk. The file at
    /// `MediaStorage.url(for: .audio, id: contentId)` must already
    /// exist (recording flow wrote it; file picker adopted it).
    ///
    /// Returns the created element on success so the caller can
    /// chain on selection, scroll-into-view, etc.
    @discardableResult
    static func commit(
        contentId: UUID,
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize,
        durationSeconds: Double,
        transcript: String = ""
    ) -> PageElement? {
        let context = StorageService.shared.context

        let normalizedHeight = Self.normalizedHeight(for: Double(pageSize.height))
        let baseZIndex = nextZIndex(forPageId: pageId, context: context)

        let element = PageElement(
            id: UUID(),
            pageId: pageId,
            notebookId: notebookId,
            kind: .audio,
            normalizedX: defaultNormalizedX,
            normalizedY: defaultNormalizedY,
            normalizedWidth: defaultNormalizedWidth,
            normalizedHeight: normalizedHeight,
            zIndex: baseZIndex
        )
        let content = AudioContent(
            id: contentId,
            filename: "\(contentId.uuidString).m4a",
            durationSeconds: durationSeconds,
            transcript: transcript
        )
        element.audioContent = content
        context.insert(element)
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[AudioCommit] save failed: \(error)")
            #endif
            return nil
        }
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
        return element
    }

    /// Update the transcript (and optionally word-level timing data)
    /// on an existing AudioContent — used by the post-recording
    /// transcription pass (SpeechTranscriber processes the M4A
    /// asynchronously after the row already exists on the page).
    static func updateTranscript(
        contentId: UUID,
        transcript: String,
        timingMap: TimingMap? = nil
    ) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<AudioContent>(
            predicate: #Predicate { $0.id == contentId }
        )
        guard let content = try? context.fetch(descriptor).first else { return }
        content.transcript = transcript
        if let timingMap { content.timingMap = timingMap }
        content.updatedAt = Date()
        do {
            try context.save()
        } catch {
            #if DEBUG
            dlog("[AudioElement] updateTranscript SAVE FAILED contentId=\(contentId): \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }

    // MARK: - Step 6: Voice Note placeholder + finalize

    /// Create an inline `PageElement(.audio)` + `AudioContent` row
    /// with `durationSeconds = 0` — the placeholder the
    /// `AudioElementView` renders in its recording state (pulsing
    /// dot + live timer) while the user is still recording. The
    /// caller (RecordingSession) calls `finalizeVoiceNote(...)` on
    /// stop to fill in the real duration so the view flips into
    /// its ready state.
    ///
    /// Returns the PageElement id so the session can track it
    /// across the recording lifetime.
    @discardableResult
    static func createRecordingPlaceholder(
        contentId: UUID,
        pageId: UUID,
        notebookId: UUID,
        pageSize: CGSize
    ) -> UUID {
        let context = StorageService.shared.context
        let normalizedHeight = Self.normalizedHeight(for: Double(pageSize.height))
        let baseZIndex = nextZIndex(forPageId: pageId, context: context)
        let elementId = UUID()
        let element = PageElement(
            id: elementId,
            pageId: pageId,
            notebookId: notebookId,
            kind: .audio,
            normalizedX: defaultNormalizedX,
            normalizedY: defaultNormalizedY,
            normalizedWidth: defaultNormalizedWidth,
            normalizedHeight: normalizedHeight,
            zIndex: baseZIndex
        )
        let content = AudioContent(
            id: contentId,
            filename: "\(contentId.uuidString).m4a",
            durationSeconds: 0,
            transcript: ""
        )
        element.audioContent = content
        context.insert(element)
        do {
            try context.save()
        } catch {
            // Voice-note placeholder save failed — the recording is
            // still rolling but its on-screen element won't render.
            // Without this log the user sees "I'm recording but
            // there's nothing on the page" with no telemetry trail.
            #if DEBUG
            dlog("[AudioElement] createRecordingPlaceholder SAVE FAILED contentId=\(contentId) elementId=\(elementId): \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
        return elementId
    }

    /// Promote a recording placeholder to its final state — writes
    /// the captured duration onto the AudioContent so the
    /// `AudioElementView` flips out of `recording` and into `ready`
    /// (play/pause/progress strip).
    static func finalizeVoiceNote(
        elementId: UUID,
        contentId: UUID,
        durationSeconds: Double
    ) {
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<AudioContent>(
            predicate: #Predicate { $0.id == contentId }
        )
        guard let content = try? context.fetch(descriptor).first else { return }
        content.durationSeconds = durationSeconds
        content.updatedAt = Date()
        do {
            try context.save()
        } catch {
            // Failure here means the AudioElementView stays stuck in
            // .recording state — pulsing dot + live timer never
            // flip to play/pause/progress chrome. The recording is
            // safe on disk; the row just doesn't know it's done.
            #if DEBUG
            dlog("[AudioElement] finalizeVoiceNote SAVE FAILED contentId=\(contentId): \(error)")
            #endif
        }
        NotificationCenter.default.post(name: .audioElementsChanged, object: nil)
    }

    /// Make publicly accessible so DictationFlowCommit can mirror
    /// the height heuristic for the audio strip placement.
    static func defaultStripHeight(forPagePoints pageHeightPoints: Double) -> Double {
        normalizedHeight(for: pageHeightPoints)
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
}

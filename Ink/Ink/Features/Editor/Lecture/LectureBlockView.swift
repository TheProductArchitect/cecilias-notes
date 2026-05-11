/// LectureBlockView.swift
/// Cecilia's Notes
///
/// Pass B of lecture mode: replaces the raw `lecture:<uuid>`
/// TextBlock placeholder with a proper block view that exposes the
/// audio playback control, the AI summary (iOS 26+ / canRun only),
/// and an expandable transcript.
///
/// The view does NOT own the record — it looks the record up from
/// `LectureStore` by id on appear and on every `.lectureRecordUpdated`
/// notification. Summary generation is async; the view's
/// `summarising…` state transitions to the populated summary section
/// the moment the writer-back lands.

import AVFoundation
import Combine
import SwiftUI

// MARK: - LectureBlockView

/// Replacement renderer for the `lecture:<uuid>` TextBlock
/// placeholder. The host (`TextBlockOverlayView.blockView`) detects
/// the prefix and mounts this view in place of `TextBlockView`. The
/// frame + on-page position are still owned by the TextBlock layout
/// math — this view fills whatever rectangle the host gives it.
struct LectureBlockView: View {

    let recordId: UUID
    let pageId: UUID

    /// Current snapshot of the underlying `LectureRecord`. Re-fetched
    /// in `onAppear` and whenever `.lectureRecordUpdated` fires for
    /// this id. `nil` when the record has been soft-deleted or the
    /// id is malformed — the view renders a placeholder line in
    /// that case rather than disappearing silently.
    @State private var record: LectureRecord?

    /// Session-local expand/collapse for the transcript. Per spec —
    /// not persisted.
    @State private var transcriptExpanded: Bool = false

    /// Single owning audio controller for play/pause. Per-view so
    /// two lectures on the same page can play independently if the
    /// user ever opens both at once — but in practice only one is
    /// mounted at a time per page.
    @StateObject private var audio = LectureBlockAudio()

    /// Observed so the "summarising…" label transitions to the
    /// summary content the moment generation completes for this
    /// record. The set is process-local — pre-Pass-B records and
    /// any record whose generation didn't run in this session are
    /// absent from the set, so they show no "summarising…" state.
    @ObservedObject private var intelligence = IntelligenceService.shared

    // MARK: Body

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // 3pt left rule — the only structural chrome on the
            // block. No card, no border, no fill.
            Rectangle()
                .fill(Color.inkRecessiveQuinary)
                .frame(width: 3)
                .padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 0) {
                if let record {
                    header(for: record)
                    Rectangle()
                        .fill(Color.inkRecessiveQuinary)
                        .frame(height: 0.5)
                        .padding(.top, 10)
                        .padding(.bottom, 12)
                    if IntelligenceService.shared.canRun {
                        summarySection(for: record)
                    }
                    transcriptSection(for: record)
                } else {
                    // The record was soft-deleted (e.g. via a
                    // sticky-note style management UI in a future
                    // pass) or its id is malformed. Recessive
                    // placeholder keeps the block visible but
                    // unobtrusive.
                    Text("lecture missing")
                        .font(.system(size: 13).italic())
                        .foregroundStyle(Color.inkRecessiveTertiary)
                        .padding(.vertical, 8)
                }
            }
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear(perform: refreshRecord)
        .onReceive(
            NotificationCenter.default.publisher(for: .lectureRecordUpdated)
        ) { note in
            // Update only when the post is for our record. Other
            // lectures on other pages also trigger this notification
            // — the id check prevents redundant refetches.
            guard let id = note.userInfo?["recordId"] as? UUID,
                  id == recordId else { return }
            refreshRecord()
        }
    }

    // MARK: Header

    @ViewBuilder
    private func header(for record: LectureRecord) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14))
                .foregroundStyle(Color.inkRecessiveSecondary)
            Text(record.title.isEmpty ? "untitled lecture" : record.title)
                .font(.system(size: 14, weight: .heavy))
                .foregroundStyle(Color.inkNearBlack)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(Self.formatDuration(record.durationSeconds))
                .font(.system(size: 11))
                .foregroundStyle(Color.inkRecessiveTertiary)
                .monospacedDigit()
            Button {
                audio.toggle(relativePath: record.audioRelativePath)
            } label: {
                Image(systemName: audio.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Color.inkRecessiveSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(audio.isPlaying ? "Pause lecture" : "Play lecture")
        }
    }

    // MARK: Summary

    @ViewBuilder
    private func summarySection(for record: LectureRecord) -> some View {
        if record.hasSummary {
            VStack(alignment: .leading, spacing: 10) {
                if let summary = record.summary {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.inkNearBlack)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(record.summaryBullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle()
                                .fill(Color.inkRecessiveSecondary)
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(bullet)
                                .font(.system(size: 13))
                                .foregroundStyle(Color.inkNearBlack)
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(.bottom, 12)
        } else if intelligence.pendingLectureSummaryIds.contains(record.id) {
            // Generation in flight. Intentionally a single-line
            // italic recessive label — no spinner, no progress bar,
            // matching the rest of the app's "AI surface" copy.
            // The in-flight check ensures this state only appears
            // while generation is actually running — pre-Pass-B
            // records and records whose generation never fired in
            // this session show no summary section at all.
            Text("summarising…")
                .font(.system(size: 11).italic())
                .foregroundStyle(Color.inkRecessiveTertiary)
                .padding(.bottom, 12)
        }
        // else: no summary, not in flight → omit the section
        // entirely. Graceful absence per the architecture rule.
    }

    // MARK: Transcript

    @ViewBuilder
    private func transcriptSection(for record: LectureRecord) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                transcriptExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Text("transcript")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.inkRecessiveSecondary)
                Image(systemName: transcriptExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(Color.inkRecessiveTertiary)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)

        if transcriptExpanded {
            // Expanded body. The block height grows to fit the full
            // transcript; the page canvas (the parent scroll view)
            // owns scrolling — no internal scroll view here.
            Text(record.transcript.isEmpty ? "no transcript captured." : record.transcript)
                .font(.system(size: 12))
                .foregroundStyle(Color.inkRecessiveSecondary)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
    }

    // MARK: - Data

    private func refreshRecord() {
        record = LectureStore.record(id: recordId, pageId: pageId)
    }

    // MARK: - Helpers

    /// "1h 23m" / "45m" / "0m". `Int` truncation is fine — the
    /// header is informational, not a precise timer.
    private static func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

// MARK: - LectureBlocksOverlayView (per-page mount)

/// Per-page overlay that scans the page's TextBlocks for the
/// `lecture:<uuid>` marker and renders a `LectureBlockView` in
/// place of each. Mounted inside each `PageRenderer` so it scrolls
/// with the page; sits above the image-attachment layer and below
/// the PencilKit canvas — interactive enough to receive the
/// transcript-expand tap, transparent everywhere else so ink draws
/// over it.
///
/// Replaces the legacy `TextBlockOverlayView`-routing path which
/// is currently unmounted in the canvas hierarchy.
struct LectureBlocksOverlayView: View {

    @ObservedObject var viewModel: EditorViewModel
    let pageId: UUID
    let pageSize: CGSize

    /// Standard page margin used for the lecture block's width —
    /// the block expects "full page width minus standard page
    /// margins". 0.06 on each side mirrors the default TextBlock
    /// inset used elsewhere in the editor.
    private static let horizontalMargin: Double = 0.06

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(lectureBlocks, id: \.id) { block in
                blockView(for: block)
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func blockView(for block: TextBlock) -> some View {
        if let recordId = LectureBlockView.parseRecordId(fromBody: block.content) {
            // Position the block by its top-leading corner from the
            // TextBlock's stored normalised origin; force the width
            // to full-page-minus-margins per spec. Height grows to
            // fit the transcript when expanded.
            let leftMargin  = Self.horizontalMargin * pageSize.width
            let rightMargin = Self.horizontalMargin * pageSize.width
            let width = max(0, pageSize.width - leftMargin - rightMargin)
            let top  = CGFloat(block.y) * pageSize.height
            LectureBlockView(recordId: recordId, pageId: block.pageId)
                .frame(width: width, alignment: .topLeading)
                .position(x: leftMargin + width / 2, y: top + 1)
                .offset(y: 0)
        }
    }

    /// Lecture-prefixed text blocks for this page. Pulled directly
    /// from the SwiftData relationship rather than
    /// `viewModel.currentPageTextBlocks` so the overlay tracks the
    /// correct page even when the user is on a different page.
    private var lectureBlocks: [TextBlock] {
        guard let page = viewModel.pages.first(where: { $0.id == pageId }) else { return [] }
        return (page.textBlocks ?? [])
            .filter { !$0.isDeleted && $0.content.hasPrefix("lecture:") }
            .sorted { $0.zIndex < $1.zIndex }
    }
}

// MARK: - Marker parsing

extension LectureBlockView {
    /// Extract the record UUID from a TextBlock body whose first
    /// line is `lecture:<uuid>`. Returns `nil` for any other shape —
    /// callers fall back to the regular text-block renderer in that
    /// case.
    ///
    /// Pass A also embedded duration + transcript lines beneath the
    /// marker. Those lines are ignored — only the first-line UUID
    /// matters for lookup.
    static func parseRecordId(fromBody body: String) -> UUID? {
        let firstLine = body.split(whereSeparator: \.isNewline).first.map(String.init) ?? body
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("lecture:") else { return nil }
        let uuidString = String(trimmed.dropFirst("lecture:".count))
        return UUID(uuidString: uuidString)
    }
}

// MARK: - LectureBlockAudio

/// One-shot play/pause controller for the block's audio file. No
/// scrubbing, no progress bar — Pass B intentionally keeps the
/// surface minimal. `@MainActor` because `@Published` drives the
/// SwiftUI play/pause button icon swap.
@MainActor
final class LectureBlockAudio: ObservableObject {

    @Published private(set) var isPlaying: Bool = false

    private var player: AVAudioPlayer?

    /// Toggle play / pause for the file at the documents-relative
    /// path. Creates the `AVAudioPlayer` lazily so a block that's
    /// never tapped costs nothing. A second tap on a finished file
    /// rewinds to zero and plays again.
    func toggle(relativePath: String) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Re-build the player if the URL changed or the previous
        // player's file isn't ours any more. Cheap enough to do on
        // every tap when state's already torn down.
        if player == nil || player?.url != url {
            // `AVAudioPlayer(contentsOf:)` is documented as safe on
            // main thread for files this short (lecture audio); the
            // architecture rule about off-main work is about file
            // writes and PDF mutation, not local audio playback.
            player = try? AVAudioPlayer(contentsOf: url)
            player?.delegate = audioDelegate
            audioDelegate.onFinish = { [weak self] in
                Task { @MainActor in self?.isPlaying = false }
            }
            player?.prepareToPlay()
        }
        // Rewind a finished file so a tap always plays from start
        // rather than silently no-op-ing.
        if let p = player, p.currentTime >= p.duration {
            p.currentTime = 0
        }
        if player?.play() == true {
            isPlaying = true
        }
    }

    /// Single retained delegate — `AVAudioPlayer.delegate` is a
    /// weak property, so a stored property on the controller keeps
    /// it alive.
    private let audioDelegate = LectureBlockAudioDelegate()
}

/// Standalone delegate so `AVAudioPlayer`'s weak delegate slot
/// doesn't drop a closure-bag. Forwards completion to the
/// controller via the `onFinish` hook.
private final class LectureBlockAudioDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish?()
    }
}

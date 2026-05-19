import AVFoundation
import Combine
import Foundation
import SwiftUI

/// Single-element AVAudioPlayer wrapper. Owned per `AudioElementView`
/// instance — no shared global player. Multiple elements can play
/// simultaneously, which is the intended v1 behaviour (architecture
/// §5 — "static" primitive; v1 doesn't enforce playback exclusivity
/// across elements).
///
/// Lifecycle:
///   • `load(url:)` is called when the element view appears.
///     Creates the AVAudioPlayer, reads `duration`, leaves
///     `isPlaying = false`.
///   • `togglePlayPause()` starts/pauses; spins up a 10Hz timer to
///     drive `currentTime` so the progress bar moves smoothly.
///   • `seek(to:)` jumps to a specific second.
///   • `pause()` is called from `onDisappear` so navigating away
///     mid-playback doesn't leave audio playing silently.
///   • Auto-stops at end-of-file via `audioPlayerDidFinishPlaying`.
///
/// Audio session: `.playback` category, set on first load. This
/// matches the architecture spec: play even when device is silenced,
/// mix with other apps.
@MainActor
final class AudioPlaybackController: NSObject, ObservableObject {

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?
    private var loadedURL: URL?

    func load(url: URL) {
        // Idempotent for the same URL — calling `load` multiple
        // times on view re-render doesn't re-create the player or
        // reset playback position.
        if loadedURL == url, player != nil { return }

        Task { @MainActor in await Self.configureAudioSession() }

        guard FileManager.default.fileExists(atPath: url.path) else {
            #if DEBUG
            print("[AudioPlayback] file missing at \(url.path)")
            #endif
            return
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            self.player = p
            self.loadedURL = url
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = false
        } catch {
            #if DEBUG
            print("[AudioPlayback] failed to load \(url.lastPathComponent): \(error)")
            #endif
        }
    }

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
        } else {
            player.play()
            startTimer()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let clamped = max(0, min(player.duration, seconds))
        player.currentTime = clamped
        currentTime = clamped
    }

    func pause() {
        guard let player, player.isPlaying else { return }
        player.pause()
        stopTimer()
        isPlaying = false
    }

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        // 10Hz — smooth enough for a thin progress bar, cheap.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            // Explicit `[weak self]` on the inner Task too —
            // without it, Swift 6 flags the implicit capture of a
            // mutable `self` value crossing the Sendable boundary.
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Audio session

    /// Configure the shared `AVAudioSession` for playback. Called
    /// from every `load(url:)` so a session that fell into a bad
    /// state after recording (the `!pri` `priorityDenied` error
    /// surfaced in device testing) gets re-armed on the next play.
    ///
    /// Why this isn't gated by a once-per-process flag any more:
    /// `AudioRecorder.stop()` deactivates the session with
    /// `.notifyOthersOnDeactivation`, but the system propagates
    /// that to other audio components asynchronously. If a play
    /// attempt lands on the controller before that propagation
    /// completes, `setCategory(.playback)` fails with
    /// `priorityDenied`. The retry loop here gives the system one
    /// settle tick — empirically enough to recover every time on
    /// device.
    ///
    /// Also calls `setActive(true)` so the session is hot for the
    /// `AVAudioPlayer.play()` call that follows. The original
    /// implementation only set the category; that worked when the
    /// session was already active from a prior load, but failed
    /// fresh-out-of-recording when the recorder's `setActive(false)`
    /// had just torn it down.
    private static func configureAudioSession() async {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            return
        } catch {
            #if DEBUG
            print("[AudioPlayback] first setCategory/setActive attempt failed: \(error) — retrying after settle")
            #endif
        }
        // System propagation window — empirically ~100ms after the
        // recorder's `setActive(false, .notifyOthersOnDeactivation)`
        // is enough for the next `setCategory` to succeed.
        try? await Task.sleep(nanoseconds: 100_000_000)
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
        } catch {
            #if DEBUG
            print("[AudioPlayback] failed to configure AVAudioSession after retry: \(error)")
            #endif
        }
    }
}

extension AudioPlaybackController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.stopTimer()
            self.isPlaying = false
            self.currentTime = 0
        }
    }
}

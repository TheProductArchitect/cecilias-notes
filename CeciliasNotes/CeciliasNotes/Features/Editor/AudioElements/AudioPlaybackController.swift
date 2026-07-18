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
        #if DEBUG
        dlog("[AudioPlayback] load() entered url=\(url.lastPathComponent) loadedURL=\(loadedURL?.lastPathComponent ?? "nil") hasPlayer=\(player != nil)")
        #endif
        // Idempotent for the same URL — calling `load` multiple
        // times on view re-render doesn't re-create the player or
        // reset playback position. Exception: a player with
        // `duration <= 0` was built from an incomplete file (the
        // recording hadn't finished flushing when `load` first ran);
        // allow re-creation so a later `load` recovers it.
        if loadedURL == url, let p = player, p.duration > 0 {
            #if DEBUG
            dlog("[AudioPlayback] load() idempotent skip — same URL, player live, duration=\(duration)")
            #endif
            return
        }

        // Step note: session configuration was previously
        // fire-and-forget here. That race let `togglePlayPause`
        // run `player.play()` before `setCategory(.playback)`
        // completed, which silently failed under the
        // `!pri` / `priorityDenied` device-state inherited from a
        // prior recording. Configuration is now driven from
        // `togglePlayPause` (await-then-play) so the session is
        // guaranteed hot before playback begins. `load` only
        // prepares the file + decoder.

        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        #if DEBUG
        dlog("[AudioPlayback] load() file check — exists=\(exists) size=\(size) path=\(url.path)")
        #endif
        guard exists else {
            #if DEBUG
            dlog("[AudioPlayback] load() ABORT — file missing at \(url.path)")
            #endif
            return
        }
        if size == 0 {
            #if DEBUG
            dlog("[AudioPlayback] load() WARN — file is 0 bytes; recording likely captured nothing")
            #endif
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            let prepared = p.prepareToPlay()
            self.player = p
            self.loadedURL = url
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = false
            #if DEBUG
            dlog("[AudioPlayback] load() OK — prepared=\(prepared) duration=\(p.duration) numberOfChannels=\(p.numberOfChannels) format=\(String(describing: p.format))")
            #endif
        } catch {
            #if DEBUG
            dlog("[AudioPlayback] load() THROW — failed to construct AVAudioPlayer for \(url.lastPathComponent): \(error)")
            #endif
        }
    }

    func togglePlayPause() {
        guard let player else {
            return
        }
        if player.isPlaying {
            player.pause()
            stopTimer()
            isPlaying = false
        } else {
            // Configure the session BEFORE play() so the recorder's
            // `.playAndRecord` residue can't outrace us. The Task is
            // MainActor-isolated so `self.player.play()` runs on the
            // same actor that owns `isPlaying` + the progress timer.
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                await Self.configureAudioSession()
                guard let player = self.player else {
                    return
                }
                _ = player.prepareToPlay()
                let didPlay = player.play()
                self.startTimer()
                // Only claim the playing state when AVAudioPlayer
                // actually accepted the play — previously this set
                // true unconditionally, leaving a stuck play badge
                // when the session start was refused.
                self.isPlaying = didPlay
            }
        }
    }

    // MARK: - DEBUG direct play

    /// Bypass every layer of the normal flow and play the file
    /// directly with the minimum possible session setup. Wired to
    /// a long-press on the play button (`AudioElementView`) so the
    /// user can compare: if normal tap doesn't work but long-press
    /// does, the regression is in the controller flow rather than
    /// the file / session / hardware layer.
    func debugPlayDirectly(url: URL) {
        #if DEBUG
        dlog("[AudioPlayback] debugPlayDirectly entered, url=\(url.lastPathComponent)")
        let exists = FileManager.default.fileExists(atPath: url.path)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? -1
        dlog("[AudioPlayback] debugPlayDirectly file exists=\(exists), size=\(size)")
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            dlog("[AudioPlayback] debugPlayDirectly session configured")
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.prepareToPlay()
            let didPlay = p.play()
            dlog("[AudioPlayback] debugPlayDirectly player.play() = \(didPlay), duration=\(p.duration)")
            // Hold a strong reference so the AVAudioPlayer survives.
            self.player = p
            self.loadedURL = url
            self.duration = p.duration
            self.currentTime = 0
            self.isPlaying = didPlay
            if didPlay { startTimer() }
        } catch {
            dlog("[AudioPlayback] debugPlayDirectly threw: \(error)")
        }
        #endif
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
        var firstCategoryOK = false
        do {
            try session.setCategory(.playback, mode: .default, options: [])
            firstCategoryOK = true
        } catch {
        }
        if firstCategoryOK {
            do {
                try session.setActive(true)
                #if DEBUG
                #endif
                return
            } catch {
            }
        }
        // System propagation window — empirically ~100ms after the
        // recorder's `setActive(false, .notifyOthersOnDeactivation)`
        // is enough for the next `setCategory` to succeed.
        try? await Task.sleep(nanoseconds: 100_000_000)
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
        }
        do {
            try session.setActive(true)
        } catch {
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

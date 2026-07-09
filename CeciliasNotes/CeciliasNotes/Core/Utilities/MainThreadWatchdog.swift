import Foundation

/// Detects main-thread stalls. A background queue pings every
/// `interval`; the main runloop must acknowledge within `threshold`
/// or `SessionHealth` records a hang (launch recovery reads this on
/// the next cold start). DEBUG builds also log a stack trace.
///
/// Install once at launch (`CeciliasNotesApp.init` / `MacAppDelegate`).
enum MainThreadWatchdog {

    private static let engine = _Engine()

    static func install(
        threshold: TimeInterval = 2.0,
        interval: TimeInterval = 0.5
    ) {
        engine.install(threshold: threshold, interval: interval)
    }

    private final class _Engine: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.ceciliasnotes.main-thread-watchdog")
        private var isInstalled = false
        private var pendingPingID = 0
        private var lastAckID = 0

        func install(threshold: TimeInterval, interval: TimeInterval) {
            queue.sync {
                guard !isInstalled else { return }
                isInstalled = true
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let timer = Timer(timeInterval: min(0.1, interval / 2), repeats: true) { [weak self] _ in
                    self?.queue.async {
                        guard let self else { return }
                        self.lastAckID = self.pendingPingID
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                _ = timer
            }

            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + interval, repeating: interval)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.pendingPingID &+= 1
                let ping = self.pendingPingID
                let ack = self.lastAckID
                guard ping > ack else { return }

                self.queue.asyncAfter(deadline: .now() + threshold) { [weak self] in
                    guard let self else { return }
                    guard self.pendingPingID > self.lastAckID,
                          self.pendingPingID >= ping else { return }
                    SessionHealth.recordMainThreadHangFromWatchdog()
                    #if DEBUG
                    let stack = Thread.callStackSymbols.prefix(40).joined(separator: "\n")
                    dlog(
                        """
                        [MainThreadWatchdog] Main thread unresponsive for ≥\(threshold)s (ping #\(ping)).
                        Capture stacks from all threads in Instruments → Hangs if this reproduces.
                        Watchdog queue stack:
                        \(stack)
                        """
                    )
                    #endif
                }
            }
            source.resume()
        }
    }
}

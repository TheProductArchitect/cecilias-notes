import Foundation
#if DEBUG
import Darwin
#endif

#if DEBUG
/// Fixed C buffer + flags written ONLY by the SIGPROF handler (which
/// runs on the interrupted main thread) and read by the watchdog
/// queue after `hangStackReady` flips. Diagnostic-only scaffolding —
/// the tiny race on the flag is acceptable for a debug stack dump.
nonisolated(unsafe) private let hangStackBuffer =
    UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 128)
nonisolated(unsafe) private var hangStackCount: Int32 = 0
nonisolated(unsafe) private var hangStackReady: Int32 = 0
#endif

/// Detects main-thread stalls. A background queue pings every
/// `interval`; the main runloop must acknowledge within `threshold`
/// or `SessionHealth` records a hang (launch recovery reads this on
/// the next cold start).
///
/// DEBUG builds also dump THE MAIN THREAD'S OWN STACK at hang time:
/// the watchdog raises SIGPROF on the main pthread, the handler runs
/// on the interrupted main thread and captures `backtrace()` into a
/// static buffer, and the watchdog symbolicates + logs it. This is
/// the "what is main actually stuck on" line the device freeze hunts
/// kept missing — Performance Diagnostics faults only sample
/// framework frames, and `Thread.callStackSymbols` on the watchdog
/// queue described the wrong thread.
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
        #if DEBUG
        /// Captured on the main thread during install; read from the
        /// watchdog queue when raising the sampling signal. Benign
        /// race — worst case the first hang goes unsampled.
        private var mainPThread: pthread_t?
        #endif

        func install(threshold: TimeInterval, interval: TimeInterval) {
            queue.sync {
                guard !isInstalled else { return }
                isInstalled = true
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if DEBUG
                self.mainPThread = pthread_self()
                Self.installHangSignalHandler()
                #endif
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
                    self.dumpMainThreadStack(threshold: threshold, ping: ping)
                    #endif
                }
            }
            source.resume()
        }

        #if DEBUG
        private static func installHangSignalHandler() {
            var action = sigaction()
            action.__sigaction_u.__sa_handler = { _ in
                // Runs ON the (hung) main thread. backtrace() into a
                // pre-allocated buffer — no allocation, no locks.
                hangStackCount = backtrace(hangStackBuffer, 128)
                hangStackReady = 1
            }
            sigemptyset(&action.sa_mask)
            action.sa_flags = 0
            sigaction(SIGPROF, &action, nil)
        }

        /// Raise SIGPROF on the main pthread, wait briefly for the
        /// handler to fill the buffer, then symbolicate + log. Runs
        /// on the watchdog queue.
        private func dumpMainThreadStack(threshold: TimeInterval, ping: Int) {
            guard let main = mainPThread else {
                dlog("[MainThreadWatchdog] hang ≥\(threshold)s (ping #\(ping)) — main pthread unknown, no sample")
                return
            }
            hangStackReady = 0
            hangStackCount = 0
            guard pthread_kill(main, SIGPROF) == 0 else {
                dlog("[MainThreadWatchdog] hang ≥\(threshold)s (ping #\(ping)) — pthread_kill failed")
                return
            }
            var spins = 0
            while hangStackReady == 0 && spins < 200 {   // ≤100 ms
                usleep(500)
                spins += 1
            }
            guard hangStackReady == 1, hangStackCount > 0,
                  let symbols = backtrace_symbols(hangStackBuffer, hangStackCount)
            else {
                dlog("[MainThreadWatchdog] hang ≥\(threshold)s (ping #\(ping)) — signal sample did not land (main may be in an uninterruptible syscall)")
                return
            }
            var lines: [String] = []
            lines.reserveCapacity(Int(hangStackCount))
            for i in 0..<Int(hangStackCount) {
                if let s = symbols[i] { lines.append(String(cString: s)) }
            }
            free(symbols)
            dlog(
                """
                [MainThreadWatchdog] MAIN THREAD unresponsive ≥\(threshold)s (ping #\(ping)) — main thread stack at sample time:
                \(lines.joined(separator: "\n"))
                """
            )
        }
        #endif
    }
}

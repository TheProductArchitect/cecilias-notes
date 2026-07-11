import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit

/// Production ANR / crash telemetry. The OS itself collects hang,
/// crash, and disk-write-exceedance diagnostics for RELEASE builds
/// in the field — the one environment where none of the DEBUG
/// instruments (watchdog stack dump, forensics logs) exist. This
/// week's freeze hunt burned six device-capture round-trips before
/// a user-supplied `.ips` finally named the defect; MetricKit
/// delivers that same class of report into the app automatically.
///
/// Payloads arrive on a background queue (typically on the next
/// launch after an incident), get written to
/// `Documents/Diagnostics/*.json`, and are summarized to the
/// console. Pull them via the Xcode Devices window (download
/// container) or share them from the Files app.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {

    static let shared = MetricKitCollector()

    /// Idempotent. Call once at launch.
    func start() {
        MXMetricManager.shared.add(self)
    }

    /// Crash / hang / CPU- and disk-exceedance diagnostics — the
    /// actionable payloads, each with call stacks.
    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        write(payloads.map { ($0.jsonRepresentation(), "diagnostic") })
    }

    /// Aggregate metrics (hang rate, launch times). Keep the most
    /// recent only — the trend lives in App Store Connect; the local
    /// copy is just for quick inspection.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        write(payloads.suffix(1).map { ($0.jsonRepresentation(), "metrics") })
    }

    nonisolated private func write(_ items: [(Data, String)]) {
        guard !items.isEmpty else { return }
        guard let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first else { return }
        let dir = docs.appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        for (index, item) in items.enumerated() {
            let url = dir.appendingPathComponent("\(item.1)-\(stamp)-\(index).json")
            try? item.0.write(to: url)
            dlog("[MetricKit] wrote \(item.1) payload → \(url.lastPathComponent) (\(item.0.count) bytes)")
        }
    }
}
#endif

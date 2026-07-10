import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity

/// Every outbound `MCSession.send` in the app leaves through this
/// serial queue. `MCSession.send` is thread-safe, but with `.reliable`
/// it can block for SECONDS when the underlying DTLS link is dying
/// ("sendmsg error: No route to host" retries) while MCSession still
/// lists the peer as connected — a peer that left the LAN takes tens
/// of seconds to drop out of `connectedPeers`. Calling it on the main
/// thread was an ANR: stroke saves broadcast notebook-changed hints
/// every ~1.2 s while drawing, and each hint wedged on the dead link.
///
/// Sends are fire-and-forget: multipeer is a best-effort accelerator,
/// receiver imports are idempotent, and iCloud remains the durable
/// path — so a dropped payload costs latency, never data.
enum MultipeerSendQueue {
    nonisolated private static let queue = DispatchQueue(
        label: "app.ceciliasnotes.multipeer.send",
        qos: .userInitiated
    )

    nonisolated static func enqueue(_ payload: Data, to peer: MCPeerID, session: MCSession) {
        queue.async {
            try? session.send(payload, toPeers: [peer], with: .reliable)
        }
    }
}

/// Lightweight multipeer hint that a notebook changed on a paired peer.
/// When both apps are open and connected, receivers refresh the library
/// immediately; otherwise iCloud remains the passive sync path.
enum MultipeerNotebookHint {

    static let changedNotification = Notification.Name("ceciliasnotes.multipeer.notebookChanged")

    static func send(notebookId: UUID, to peer: MCPeerID, session: MCSession, key: SymmetricKey) {
        let body = try? JSONEncoder().encode(["notebookId": notebookId.uuidString])
        let bodyData = body ?? Data()
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        let header: [String: Any] = [
            "type": "notebook-changed",
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }
        let signed = headerData + bodyData
        let tag = Data(HMAC<SHA256>.authenticationCode(for: signed, using: key))
        var payload = Data()
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        payload.append(bodyData)
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
    }

    static func notebookId(from body: Data) -> UUID? {
        struct Payload: Decodable { let notebookId: String }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: body),
              let id = UUID(uuidString: decoded.notebookId)
        else { return nil }
        return id
    }

    /// Coalescing state for `broadcastNotebookChanged`. The editor
    /// calls it from every debounced stroke save (~1.2 s cadence
    /// while drawing) and every dictation save (1/s). Each raw call
    /// walks the connected peers and enqueues a payload per peer —
    /// on a stale link every one of those feeds the DTLS retry storm
    /// ("No route to host" log spam). Receivers only use the hint to
    /// refresh, so one leading send plus one trailing send per quiet
    /// period loses nothing.
    @MainActor private static var lastHintAt: [UUID: Date] = [:]
    @MainActor private static var trailingHint: [UUID: Task<Void, Never>] = [:]
    private static let hintInterval: TimeInterval = 3.0

    @MainActor
    static func broadcastNotebookChanged(notebookId: UUID) {
        let now = Date()
        if now.timeIntervalSince(lastHintAt[notebookId] ?? .distantPast) >= hintInterval {
            lastHintAt[notebookId] = now
            sendHintNow(notebookId: notebookId)
        } else if trailingHint[notebookId] == nil {
            trailingHint[notebookId] = Task { @MainActor in
                try? await Task.sleep(for: .seconds(hintInterval))
                trailingHint[notebookId] = nil
                lastHintAt[notebookId] = Date()
                sendHintNow(notebookId: notebookId)
            }
        }
    }

    @MainActor
    private static func sendHintNow(notebookId: UUID) {
        MultipeerSyncService.shared.broadcastNotebookChanged(notebookId: notebookId)
        MultipeerSendService.shared.broadcastNotebookChanged(notebookId: notebookId)
    }
}

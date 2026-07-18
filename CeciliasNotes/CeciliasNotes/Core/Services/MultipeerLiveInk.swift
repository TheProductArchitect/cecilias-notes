import CryptoKit
import Foundation

/// Live-ink streaming between paired SAME-HOUSEHOLD devices (protocol
/// v2.4, message type `"live-ink"`). While a user draws, the sender
/// streams throttled FULL-page drawing snapshots to connected peers;
/// a receiver with the same notebook open renders them as an
/// EPHEMERAL overlay — never persisted, never written to SwiftData.
/// CloudKit remains the only durable path; the overlay exists to
/// remove the CloudKit round-trip from the *visible* latency, and it
/// clears itself the moment the durable rows land (or on TTL).
///
/// Why full snapshots, not deltas: a snapshot is idempotent — a
/// dropped or reordered message costs one refresh interval, never a
/// desync; erases and stroke edits need no special casing. Page ink
/// is tens-to-hundreds of KB; on a LAN at a few messages per second
/// this is noise. Why same-household only: a cross-account peer may
/// not have the notebook at all, and live ink from someone else's
/// account is a privacy surprise — the cross-account lane stays
/// explicit ("Send to Device").
///
/// This file is transport only (Foundation + CryptoKit) — drawing
/// bytes are opaque here so the Mac target can compile it without
/// PencilKit. Encode/decode of `PKDrawing` lives with the canvas.
enum MultipeerLiveInk {

    /// Posted by the receive lanes after HMAC verification. userInfo:
    /// `notebookId: UUID`, `pageId: UUID`, `seq: UInt64`,
    /// `drawingData: Data` (PKDrawing dataRepresentation).
    static let receivedNotification = Notification.Name("ceciliasnotes.multipeer.liveInkReceived")

    enum UserInfoKey {
        // nonisolated: read inside the canvas's notification-observer
        // closure, which is Sendable/nonisolated — plain String
        // constants must not inherit the default MainActor isolation.
        nonisolated static let notebookId = "notebookId"
        nonisolated static let pageId = "pageId"
        nonisolated static let seq = "seq"
        nonisolated static let drawingData = "drawingData"
    }

    /// Snapshots above this size stop streaming (the page still syncs
    /// via CloudKit; we just skip the live preview). A page has to be
    /// EXTREMELY ink-dense to get here.
    static let maxSnapshotBytes = 4 * 1024 * 1024
    /// Minimum interval between snapshots per page. PencilKit fires
    /// one drawing-changed per committed stroke, so this bounds a
    /// fast writer to ~4 messages/s.
    static let minSendInterval: TimeInterval = 0.25

    // MARK: - Payload (pure, unit-tested)

    /// `[4-byte BE header length][header JSON][32-byte HMAC][body]`
    /// with HMAC over header || body — identical framing to `"file"`
    /// and `"notebook-changed"` so both receive lanes parse it with
    /// their existing envelope code.
    ///
    /// Body layout (binary, no base64 inflation):
    /// `[16B notebookId][16B pageId][8B seq BE][drawing bytes]`.
    nonisolated static func buildPayload(
        notebookId: UUID,
        pageId: UUID,
        seq: UInt64,
        drawingData: Data,
        key: SymmetricKey
    ) -> Data? {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        let header: [String: Any] = [
            "type": "live-ink",
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return nil }

        var body = Data(capacity: 40 + drawingData.count)
        body.append(contentsOf: uuidBytes(notebookId))
        body.append(contentsOf: uuidBytes(pageId))
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { body.append(contentsOf: $0) }
        body.append(drawingData)

        let tag = Data(HMAC<SHA256>.authenticationCode(for: headerData + body, using: key))
        var payload = Data(capacity: 4 + headerData.count + 32 + body.count)
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        payload.append(body)
        return payload
    }

    nonisolated struct ParsedBody: Equatable, Sendable {
        let notebookId: UUID
        let pageId: UUID
        let seq: UInt64
        let drawingData: Data
    }

    /// Inverse of the body layout above. Returns nil on anything
    /// malformed — the caller already HMAC-verified, so nil here
    /// means a protocol-version mismatch, not tampering.
    nonisolated static func parseBody(_ body: Data) -> ParsedBody? {
        guard body.count >= 40 else { return nil }
        // Data slices keep the parent's indices — normalise first.
        let bytes = [UInt8](body)
        guard let notebookId = uuid(from: Array(bytes[0..<16])),
              let pageId = uuid(from: Array(bytes[16..<32]))
        else { return nil }
        var seq: UInt64 = 0
        for b in bytes[32..<40] { seq = (seq << 8) | UInt64(b) }
        return ParsedBody(
            notebookId: notebookId,
            pageId: pageId,
            seq: seq,
            drawingData: Data(bytes[40...])
        )
    }

    nonisolated private static func uuidBytes(_ id: UUID) -> [UInt8] {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
                u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    nonisolated private static func uuid(from bytes: [UInt8]) -> UUID? {
        guard bytes.count == 16 else { return nil }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Sender facade

    /// Peers eligible for live ink: connected on either lane,
    /// key-authenticated, and KNOWN same-household. Cached briefly —
    /// this is consulted once per committed stroke and the underlying
    /// checks read UserDefaults.
    @MainActor private static var cachedPeers: [String] = []
    @MainActor private static var cachedPeersAt: Date = .distantPast

    @MainActor
    static func livePeers() -> [String] {
        let now = Date()
        if now.timeIntervalSince(cachedPeersAt) < 3.0 { return cachedPeers }
        cachedPeersAt = now
        cachedPeers = MultipeerNotebookShare.connectedAuthenticatedPeerNames()
            .filter { MultipeerNotebookShare.isSameHousehold(peerName: $0) == true }
        return cachedPeers
    }

    /// Leading-edge throttle per page. Returns true when the caller
    /// should send NOW; false means "inside the window" — the caller
    /// schedules a trailing re-read so the last stroke of a burst is
    /// never lost.
    @MainActor private static var lastSentAt: [UUID: Date] = [:]

    @MainActor
    static func shouldSendNow(pageId: UUID) -> Bool {
        let now = Date()
        guard now.timeIntervalSince(lastSentAt[pageId] ?? .distantPast) >= minSendInterval else {
            return false
        }
        lastSentAt[pageId] = now
        return true
    }

    @MainActor private static var seqByPage: [UUID: UInt64] = [:]

    /// Build + enqueue one snapshot to every live peer. Call with the
    /// drawing ALREADY encoded (encode off-main — it's the expensive
    /// step). Sends ride `MultipeerSendQueue`, never the main thread.
    @MainActor
    static func broadcast(notebookId: UUID, pageId: UUID, drawingData: Data) {
        guard drawingData.count <= maxSnapshotBytes else {
            #if DEBUG
            dlog("[LiveInk] snapshot too large (\(drawingData.count)B) — skipping live preview for page \(pageId.uuidString.prefix(8))")
            #endif
            return
        }
        let peers = livePeers()
        guard !peers.isEmpty else { return }
        let seq = (seqByPage[pageId] ?? 0) + 1
        seqByPage[pageId] = seq
        for name in peers {
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: name),
                  let payload = buildPayload(
                    notebookId: notebookId, pageId: pageId,
                    seq: seq, drawingData: drawingData, key: key
                  )
            else { continue }
            if !MultipeerSyncService.shared.sendPayload(payload, toPeerNamed: name) {
                _ = MultipeerSendService.shared.sendPayload(payload, toPeerNamed: name)
            }
        }
    }
}

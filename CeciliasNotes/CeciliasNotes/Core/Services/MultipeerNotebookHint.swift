import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity

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
        try? session.send(payload, toPeers: [peer], with: .reliable)
    }

    static func notebookId(from body: Data) -> UUID? {
        struct Payload: Decodable { let notebookId: String }
        guard let decoded = try? JSONDecoder().decode(Payload.self, from: body),
              let id = UUID(uuidString: decoded.notebookId)
        else { return nil }
        return id
    }

    @MainActor
    static func broadcastNotebookChanged(notebookId: UUID) {
        MultipeerSyncService.shared.broadcastNotebookChanged(notebookId: notebookId)
        MultipeerSendService.shared.broadcastNotebookChanged(notebookId: notebookId)
    }
}

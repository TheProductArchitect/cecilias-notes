import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity

/// Notebook sharing over the paired multipeer link, for devices on
/// the SAME Wi-Fi but DIFFERENT Apple Accounts (roommates, project
/// partners, a shared family iPad). Same-account devices don't need
/// this — CloudKit syncs their library natively and importing a
/// mirror alongside CloudKit would duplicate content, so
/// `sendablePeers()` filters same-household peers out.
///
/// The wire format is the existing `"file"` payload: the receiver
/// writes it into the iCloud Inbox and `CeciliasNotesImporter` takes
/// it from there (merge-by-default — a re-send never clobbers edits
/// the receiver made to their copy).
@MainActor
enum MultipeerNotebookShare {

    struct Peer: Identifiable, Equatable {
        let name: String
        /// nil = unknown (peer paired before hash exchange shipped).
        let sameHousehold: Bool?
        var id: String { name }
    }

    enum SendResult: Equatable {
        case sent(peerName: String)
        case tooLarge
        case exportFailed
        case notConnected
    }

    // MARK: - Household bookkeeping

    /// `[peerName: householdTokenHash]` learned during pairing and
    /// discovery. Plain UserDefaults — the hash is already public on
    /// the LAN via discoveryInfo, nothing secret to protect.
    private static let householdMapKey = "ceciliasnotes.multipeer.householdByPeer"

    static func recordHouseholdHash(_ hash: String?, forPeerName name: String) {
        guard let hash, !hash.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: householdMapKey) as? [String: String] ?? [:]
        guard map[name] != hash else { return }
        map[name] = hash
        UserDefaults.standard.set(map, forKey: householdMapKey)
    }

    /// Same Apple Account? nil when the peer's hash was never learned.
    static func isSameHousehold(peerName: String) -> Bool? {
        guard let local = MultipeerPairingStore.householdTokenHash() else { return nil }
        let map = UserDefaults.standard.dictionary(forKey: householdMapKey) as? [String: String]
        guard let remote = map?[peerName] else { return nil }
        return remote == local
    }

    // MARK: - Peers

    /// Connected, key-authenticated peers eligible for "Send to
    /// Device": different Apple Account, or unknown (old pairings).
    static func sendablePeers() -> [Peer] {
        connectedAuthenticatedPeerNames()
            .map { Peer(name: $0, sameHousehold: isSameHousehold(peerName: $0)) }
            .filter { $0.sameHousehold != true }
    }

    static func connectedAuthenticatedPeerNames() -> [String] {
        var names = Set<String>()
        for name in MultipeerSyncService.shared.connectedPeerNames {
            if MultipeerPairingStore.sharedKey(forPeerName: name) != nil { names.insert(name) }
        }
        for name in MultipeerSendService.shared.connectedPeerNames {
            if MultipeerPairingStore.sharedKey(forPeerName: name) != nil { names.insert(name) }
        }
        return names.sorted()
    }

    // MARK: - Send

    @discardableResult
    static func send(notebook: Notebook, toPeerNamed name: String) -> SendResult {
        guard let key = MultipeerPairingStore.sharedKey(forPeerName: name) else {
            return .notConnected
        }
        // Full-fidelity `.ceciliabook` (all elements + media) so the
        // recipient gets the notebook AS IT IS, editable — not the
        // text-only `.inkbook` mirror. The receiver's Inbox watcher
        // routes `.ceciliabook` to `NotebookArchiveIO`.
        guard let body = NotebookArchiveIO.archiveData(for: notebook) else {
            return .exportFailed
        }
        guard body.count <= CeciliasNotesParser.maxFileBytes else {
            return .tooLarge
        }
        let payload = buildFilePayload(
            filename: "\(notebook.id.uuidString).\(NotebookArchive.fileExtension)",
            body: body,
            key: key
        )
        guard let payload else { return .exportFailed }

        if MultipeerSyncService.shared.sendPayload(payload, toPeerNamed: name) {
            return .sent(peerName: name)
        }
        if MultipeerSendService.shared.sendPayload(payload, toPeerNamed: name) {
            return .sent(peerName: name)
        }
        return .notConnected
    }

    /// `[4-byte BE header length][header JSON][32-byte HMAC][body]`,
    /// per `MULTIPEER_SYNC_PROTOCOL.md`. HMAC covers header || body.
    private static func buildFilePayload(
        filename: String,
        body: Data,
        key: SymmetricKey
    ) -> Data? {
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        let header: [String: Any] = [
            "type": "file",
            "filename": filename,
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return nil }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: headerData + body, using: key))
        var payload = Data()
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        payload.append(body)
        return payload
    }
}

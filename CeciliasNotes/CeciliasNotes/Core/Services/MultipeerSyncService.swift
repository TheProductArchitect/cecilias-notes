import Combine
import CryptoKit
import Foundation
import MultipeerConnectivity
import UIKit

/// Direct device-to-device receiver for notebooks dropped by an
/// external agent (currently `cecilias-notes-mcp` running on a Mac).
/// Sidesteps iCloud's 30 sec – 5 min sync latency when both sides
/// are on the same network.
///
/// # Security model (v2 — pairing + HMAC)
///
/// Peer-name trust is no longer enough — anyone on the same LAN can
/// name their MCPeerID "John's MacBook" and try to push. v2 layers a
/// pairing handshake + per-payload HMAC over MultipeerConnectivity's
/// TLS:
///
/// 1. **First-time pairing**. iPad enters pairing mode via
///    Settings → cloud → "show pairing code". A 6-digit code is
///    generated and shown to the user; the user types the same code
///    into the Mac MCP. Both sides run HKDF over the code (salted with
///    the peer names) to land on the same 32-byte symmetric key.
/// 2. **Pairing confirmation**. Mac sends a `pairing-hello` payload
///    HMAC-signed with the derived key. iPad recomputes the HMAC with
///    its own derived key; if they match the key is persisted in
///    Keychain (`MultipeerPairingStore`) under the Mac's peer name.
///    Pairing mode expires after 90 seconds.
/// 3. **Per-payload authentication**. Every file payload carries an
///    HMAC over header+body using the stored shared key. Unsigned
///    payloads, bad HMACs, or payloads from peers without a stored
///    key are dropped.
/// 4. **Replay protection**. Header carries a timestamp + 16-byte
///    nonce. Payloads older than 60 seconds or with a recently-seen
///    nonce are dropped.
///
/// Pre-pairing, the only payload the receiver accepts is
/// `pairing-hello`, and only while pairing mode is active.
@MainActor
final class MultipeerSyncService: NSObject, ObservableObject {

    static let shared = MultipeerSyncService()

    /// Service identifier exchanged via Bonjour. Must match the
    /// Info.plist `NSBonjourServices` entry (`_ceciliasnotes-sync._tcp`).
    static let serviceType = "ceciliasnotes-sync"

    /// How long a freshly-generated pairing code remains valid.
    static let pairingModeWindow: TimeInterval = 90

    /// Replay window — any payload with a timestamp older than this
    /// is rejected even if the HMAC is valid.
    private static let replayWindow: TimeInterval = 60

    /// User-visible status. Drives Settings caption + status line.
    enum Status: Equatable {
        case off
        case idle                       // advertising, no peers
        case pairing(code: String, expiresAt: Date)
        case connected(peerName: String)
        case receiving(peerName: String)
        case received(peerName: String, filename: String)
        case error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var pairedPeerNames: [String] = []

    // MARK: Storage keys

    private static let enabledKey = "ceciliasnotes.multipeer.enabled"

    // MARK: Private state

    private let localPeerId: MCPeerID = {
        let safe = String(UIDevice.current.name.prefix(60))
        return MCPeerID(displayName: safe)
    }()

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    /// Active pairing window. nil unless the user has tapped
    /// "show pairing code" within the last `pairingModeWindow`.
    private var activePairingCode: String?
    private var pairingExpiresAt: Date?

    /// Nonces seen in the replay window. Trimmed on every receive.
    private var recentNonces: [(nonce: String, seenAt: Date)] = []

    private override init() {
        super.init()
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        refreshPairedPeerNames()
        if isEnabled { start() }
    }

    // MARK: Public API

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled { start() } else { stop() }
    }

    /// Enter pairing mode for the next `pairingModeWindow` seconds.
    /// Returns the displayed 6-digit code so the UI can render it.
    @discardableResult
    func beginPairing() -> String {
        let code = MultipeerPairingStore.generatePairingCode()
        let expiry = Date().addingTimeInterval(Self.pairingModeWindow)
        activePairingCode = code
        pairingExpiresAt = expiry
        status = .pairing(code: code, expiresAt: expiry)
        // Auto-cancel after the window so the status reverts cleanly
        // even if no Mac connects.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingModeWindow))
            await MainActor.run {
                guard let self else { return }
                if self.activePairingCode == code {
                    self.activePairingCode = nil
                    self.pairingExpiresAt = nil
                    if case .pairing = self.status { self.status = .idle }
                }
            }
        }
        return code
    }

    func cancelPairing() {
        activePairingCode = nil
        pairingExpiresAt = nil
        if case .pairing = status { status = .idle }
    }

    func forgetPeer(_ name: String) {
        MultipeerPairingStore.forget(peerName: name)
        refreshPairedPeerNames()
    }

    func forgetAllPeers() {
        MultipeerPairingStore.forgetAll()
        refreshPairedPeerNames()
    }

    // MARK: Lifecycle

    private func start() {
        guard session == nil else { return }
        let session = MCSession(
            peer: localPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session

        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerId,
            discoveryInfo: ["app": "ceciliasnotes", "platform": "ios", "v": "2"],
            serviceType: Self.serviceType
        )
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.advertiser = advertiser

        status = .idle
    }

    private func stop() {
        advertiser?.stopAdvertisingPeer()
        advertiser = nil
        session?.disconnect()
        session = nil
        cancelPairing()
        status = .off
    }

    private func refreshPairedPeerNames() {
        pairedPeerNames = MultipeerPairingStore.pairedPeerNames()
    }

    // MARK: Payload handling

    /// Wire format (v2):
    ///
    /// ```
    /// [4 byte BE header length][header JSON][32 byte HMAC-SHA256][body]
    /// ```
    ///
    /// Header schema:
    ///
    /// ```json
    /// {
    ///   "type": "file" | "pairing-hello",
    ///   "filename": "X.inkbook",      // file type only
    ///   "timestamp": 1718817100,      // epoch seconds
    ///   "nonce": "base64-16-bytes"
    /// }
    /// ```
    ///
    /// HMAC is computed over `headerJSON || body` using the shared
    /// key derived during pairing.
    private func handlePayload(_ data: Data, from peer: MCPeerID) {
        guard data.count > 4 + 32 else {
            status = .error("Payload too small from \(peer.displayName)")
            return
        }
        let headerLen = Int(UInt32(bigEndian: data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard data.count >= 4 + headerLen + 32 else {
            status = .error("Malformed payload from \(peer.displayName)")
            return
        }
        let headerData = data.subdata(in: 4..<(4 + headerLen))
        let hmacBytes  = data.subdata(in: (4 + headerLen)..<(4 + headerLen + 32))
        let bodyData   = data.subdata(in: (4 + headerLen + 32)..<data.count)

        struct Header: Decodable {
            let type: String
            let filename: String?
            let timestamp: Int64
            let nonce: String
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
            status = .error("Bad header from \(peer.displayName)")
            return
        }

        // Replay window — clock-skew tolerant on the negative side
        // (Mac slightly ahead is fine), strict on the positive side.
        let age = Date().timeIntervalSince1970 - TimeInterval(header.timestamp)
        guard abs(age) < Self.replayWindow else {
            status = .error("Stale payload from \(peer.displayName) (age \(Int(age))s)")
            return
        }
        // Nonce de-dupe.
        let nowMinusWindow = Date().addingTimeInterval(-Self.replayWindow)
        recentNonces.removeAll { $0.seenAt < nowMinusWindow }
        if recentNonces.contains(where: { $0.nonce == header.nonce }) {
            status = .error("Replay detected from \(peer.displayName)")
            return
        }

        // Resolve the key: paired peers use their stored key; pairing
        // hellos derive a candidate key from the active pairing code.
        let signedRange = headerData + bodyData
        switch header.type {
        case "file":
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else {
                status = .error("Unpaired peer \(peer.displayName) — payload rejected")
                return
            }
            guard verifyHMAC(hmacBytes, message: signedRange, key: key) else {
                status = .error("HMAC mismatch from \(peer.displayName) — payload rejected")
                return
            }
            recentNonces.append((header.nonce, Date()))
            writeFileToInbox(filename: header.filename, body: bodyData, peer: peer)

        case "pairing-hello":
            guard let code = activePairingCode,
                  let expiresAt = pairingExpiresAt,
                  Date() < expiresAt
            else {
                status = .error("\(peer.displayName) tried to pair, but pairing mode isn't on")
                return
            }
            let candidate = MultipeerPairingStore.derivedKey(
                fromCode: code,
                localPeerName: localPeerId.displayName,
                remotePeerName: peer.displayName
            )
            guard verifyHMAC(hmacBytes, message: signedRange, key: candidate) else {
                status = .error("Wrong pairing code from \(peer.displayName) — try again")
                return
            }
            recentNonces.append((header.nonce, Date()))
            MultipeerPairingStore.store(key: candidate, forPeerName: peer.displayName)
            refreshPairedPeerNames()
            // Pairing succeeded → exit pairing mode immediately so a
            // second attacker on the LAN can't reuse the window.
            activePairingCode = nil
            pairingExpiresAt = nil
            status = .connected(peerName: peer.displayName)

        default:
            status = .error("Unknown payload type from \(peer.displayName)")
        }
    }

    private func verifyHMAC(_ tag: Data, message: Data, key: SymmetricKey) -> Bool {
        let computed = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let computedData = Data(computed)
        // Constant-time compare — short-circuit equality on a 32-byte
        // value would leak information about the first-mismatched
        // byte to a timing observer.
        guard computedData.count == tag.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<tag.count {
            diff |= tag[i] ^ computedData[i]
        }
        return diff == 0
    }

    private func writeFileToInbox(filename: String?, body: Data, peer: MCPeerID) {
        let safeName = sanitizedFilename(filename ?? "")
        guard let inbox = CeciliasNotesFileWatcher.sharedInboxURL() else {
            status = .error("iCloud inbox unavailable — can't write the file")
            return
        }
        let dest = inbox.appendingPathComponent(safeName)
        do {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try body.write(to: dest, options: .atomic)
            status = .received(peerName: peer.displayName, filename: safeName)
            CeciliasNotesFileWatcher.shared.rescan()
        } catch {
            status = .error("Couldn't save \(safeName): \(error.localizedDescription)")
        }
    }

    private func sanitizedFilename(_ raw: String) -> String {
        let stripped = raw
            .components(separatedBy: CharacterSet(charactersIn: "/\\"))
            .last ?? ""
        let ext = (stripped as NSString).pathExtension.lowercased()
        let allowed = ["inkbook", "json"]
        if !stripped.isEmpty, allowed.contains(ext) { return stripped }
        return "\(UUID().uuidString).inkbook"
    }
}

// MARK: - MCSessionDelegate

extension MultipeerSyncService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.status = .connected(peerName: peerID.displayName)
            case .notConnected:
                if case .connected = self.status { self.status = .idle }
            case .connecting:
                self.status = .receiving(peerName: peerID.displayName)
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.handlePayload(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSyncService: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self, let session = self.session else {
                invitationHandler(false, nil)
                return
            }
            // Accept the MC-level invitation unconditionally — the
            // HMAC layer above rejects anything not from a paired
            // (or pairing-mode-authorised) peer. Refusing here would
            // break the legitimate pairing handshake before the first
            // payload arrives.
            invitationHandler(true, session)
        }
    }
}

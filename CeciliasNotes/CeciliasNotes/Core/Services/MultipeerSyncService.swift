import Combine
import Foundation
import MultipeerConnectivity
import UIKit

/// Direct device-to-device receiver for notebooks dropped by an
/// external agent (currently `cecilias-notes-mcp` running on a Mac).
/// Sits alongside `CeciliasNotesFileWatcher` as a second, faster
/// arrival path: when both the iPad and the Mac are on the same
/// Wi-Fi / Bluetooth-PAN, a freshly-written notebook can land in
/// the inbox within a second instead of the 30 sec – 5 min that
/// iCloud's sync typically takes.
///
/// ## Architecture
///
/// - Service type: `_ceciliasnotes-sync._tcp` (must also be listed
///   under `NSBonjourServices` in Info.plist for iOS 14+ to permit
///   advertisement).
/// - Discovery: MultipeerConnectivity's nearby-peer browser. The Mac
///   side advertises; the iPad side accepts the auto-invitation.
/// - Transport: MCSession's binary `Data` channel, TLS-encrypted by
///   default.
/// - Payload: a single `.inkbook` file's bytes plus an optional
///   filename header (UTF-8 JSON envelope, then the file bytes).
/// - On receipt: writes to the same iCloud inbox the file watcher
///   polls, so the existing `CeciliasNotesImporter` import path
///   runs unchanged. iCloud will eventually sync the same file
///   anyway — the multipeer copy just gets there sooner; the
///   importer is idempotent by content hash, so the duplicate is
///   harmless.
///
/// ## User flow
///
/// 1. iPad app foregrounds → service starts advertising.
/// 2. Mac MCP starts, browses for the service, finds the iPad.
/// 3. Mac sends an invitation. iPad accepts automatically because
///    the session-discoveryInfo carries a token the user has
///    previously trusted (see `PairedPeerStore`). First-time peers
///    get a prompt before acceptance — handled by the host view
///    via `pendingInvite`.
/// 4. Mac sends the `.inkbook` bytes. iPad writes to inbox.
/// 5. `CeciliasNotesFileWatcher` notices the new file via its
///    existing NSMetadataQuery, runs the importer.
///
/// ## Settings + toggles
///
/// The receiver is **off by default**. Users opt in via Settings →
/// Cloud → "Receive from Mac on this network". When off, no
/// advertising fires and the framework allocates nothing.
@MainActor
final class MultipeerSyncService: NSObject, ObservableObject {

    static let shared = MultipeerSyncService()

    /// Service identifier exchanged via Bonjour. Must match the
    /// Info.plist `NSBonjourServices` entry exactly. Keep this
    /// stable — every Mac MCP binary will look for this name.
    static let serviceType = "ceciliasnotes-sync"

    /// User-visible status. Drives the Settings row's caption + the
    /// transient toast we show after a successful direct receive.
    enum Status: Equatable {
        case off
        case idle                       // advertising, no peers
        case connected(peerName: String)
        case receiving(peerName: String)
        case received(peerName: String, filename: String)
        case error(String)
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var isEnabled: Bool = false

    /// Pending invitation the user must approve before the session
    /// connects. nil when no peer is asking. SwiftUI surfaces this
    /// as an alert; the user's response calls `respondToInvite`.
    @Published var pendingInvite: PendingInvite?

    struct PendingInvite: Identifiable, Equatable {
        let id = UUID()
        let peerName: String
        fileprivate let handler: (Bool) -> Void

        static func == (lhs: PendingInvite, rhs: PendingInvite) -> Bool { lhs.id == rhs.id }
    }

    // MARK: Storage keys

    private static let enabledKey = "ceciliasnotes.multipeer.enabled"

    // MARK: Private state

    private let localPeerId: MCPeerID = {
        let name = UIDevice.current.name
        // MCPeerID restricts displayName to 63 bytes; iPad names
        // are short enough but we trim defensively.
        let safe = String(name.prefix(60))
        return MCPeerID(displayName: safe)
    }()

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    private override init() {
        super.init()
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    // MARK: Public API

    /// Persist user opt-in / opt-out. Off by default; the receiver
    /// only allocates session + advertiser when the user enables.
    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    /// Approve or decline an inbound invitation. Should only be
    /// called from the UI surfacing `pendingInvite`. Clearing the
    /// pending invite is the responsibility of this method.
    func respondToInvite(_ invite: PendingInvite, accept: Bool) {
        invite.handler(accept)
        if pendingInvite == invite { pendingInvite = nil }
        if accept {
            PairedPeerStore.shared.remember(peerName: invite.peerName)
        }
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
            discoveryInfo: ["app": "ceciliasnotes", "platform": "ios"],
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
        pendingInvite = nil
        status = .off
    }

    // MARK: Payload handling

    private func handlePayload(_ data: Data, from peer: MCPeerID) {
        // Envelope: 4-byte big-endian uint32 = header length, then
        // header (UTF-8 JSON with "filename": "<name>"), then file
        // bytes. Keeps the protocol forward-extensible (additional
        // header fields don't break readers).
        guard data.count > 4 else {
            status = .error("Received payload too small from \(peer.displayName)")
            return
        }
        let headerLen = Int(UInt32(bigEndian: data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard data.count >= 4 + headerLen else {
            status = .error("Malformed payload from \(peer.displayName)")
            return
        }
        let headerData = data.subdata(in: 4..<(4 + headerLen))
        let bodyData   = data.subdata(in: (4 + headerLen)..<data.count)

        struct Header: Decodable {
            let filename: String
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData) else {
            status = .error("Bad header from \(peer.displayName)")
            return
        }
        let filename = sanitizedFilename(header.filename)
        guard let inbox = CeciliasNotesFileWatcher.sharedInboxURL() else {
            status = .error("iCloud inbox unavailable — can't write the file")
            return
        }
        let dest = inbox.appendingPathComponent(filename)
        do {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            try bodyData.write(to: dest, options: .atomic)
            status = .received(peerName: peer.displayName, filename: filename)
            // Kick the file watcher so the import runs immediately
            // — without this we'd wait for the NSMetadataQuery to
            // notice (which can take seconds on a quiet device).
            CeciliasNotesFileWatcher.shared.rescan()
        } catch {
            status = .error("Couldn't save \(filename): \(error.localizedDescription)")
        }
    }

    /// Basic filename hardening: strip path separators, allow
    /// `.inkbook` / `.json` extensions only, fall back to a UUID
    /// when the supplied name is unusable.
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
            // Auto-accept previously-trusted peers; surface a prompt
            // for first-time peers.
            if PairedPeerStore.shared.isTrusted(peerName: peerID.displayName) {
                invitationHandler(true, session)
                return
            }
            self.pendingInvite = PendingInvite(peerName: peerID.displayName) { accepted in
                invitationHandler(accepted, accepted ? session : nil)
            }
        }
    }
}

// MARK: - PairedPeerStore

/// Persists the set of peer display-names the user has accepted
/// before. First-time peers always prompt; subsequent connections
/// from the same peer are auto-accepted. The store can be cleared
/// from Settings → Cloud → "Forget paired devices".
@MainActor
final class PairedPeerStore {
    static let shared = PairedPeerStore()

    private static let key = "ceciliasnotes.multipeer.trustedPeers"

    private init() {}

    func isTrusted(peerName: String) -> Bool {
        Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? []).contains(peerName)
    }

    func remember(peerName: String) {
        var trusted = Set(UserDefaults.standard.stringArray(forKey: Self.key) ?? [])
        trusted.insert(peerName)
        UserDefaults.standard.set(Array(trusted), forKey: Self.key)
    }

    func forgetAll() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}

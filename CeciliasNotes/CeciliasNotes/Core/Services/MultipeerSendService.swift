import Combine
import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#endif

/// Multipeer browser — discovers nearby Cecilia's Notes receivers,
/// pairs (manual code or same-Apple-Account auto-pair) and keeps
/// reconnecting to known peers on the LAN automatically. Runs on
/// every platform: the Mac browses for iPads, and iPhones/iPads
/// browse for each other so same-household devices form a live
/// link without either side being "the Mac".
@MainActor
final class MultipeerSendService: NSObject, ObservableObject {

    static let shared = MultipeerSendService()

    struct DiscoveredDevice: Identifiable, Equatable {
        let peer: MCPeerID
        let platform: String
        let householdHash: String?
        var id: String { peer.displayName }
        var label: String {
            switch platform {
            case "ios": return "\(peer.displayName) (iPhone / iPad)"
            case "macos": return "\(peer.displayName) (Mac)"
            default: return peer.displayName
            }
        }
    }

    enum Status: Equatable {
        case idle
        case browsing
        case connecting(peerName: String)
        case paired(peerName: String)
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var connectedPeerNames: [String] = []
    @Published var selectedDeviceID: String?

    private let localPeerId: MCPeerID = {
        #if canImport(UIKit)
        let name = UIDevice.current.name
        #else
        let name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
        return MCPeerID(displayName: String(name.prefix(60)))
    }()

    private var session: MCSession?
    private var browser: MCNearbyServiceBrowser?
    private var pendingCode: String?
    private var pendingFirstParty = false
    private var targetPeer: MCPeerID?
    private var pairingTimeoutTask: Task<Void, Never>?
    private var reconnectTasks: [String: Task<Void, Never>] = [:]
    /// When true, browsing stays active and known peers reconnect automatically.
    private var keepBrowsingAlive = false

    private override init() {
        super.init()
    }

    /// Browse continuously and reconnect to paired / same-household peers.
    func startBackgroundReconnect() {
        keepBrowsingAlive = true
        ensureBrowsing()
    }

    func startBrowsing() {
        keepBrowsingAlive = false
        ensureBrowsing()
    }

    private func ensureBrowsing() {
        guard browser == nil else { return }
        if case .error = status { status = .browsing }
        else if status == .idle { status = .browsing }

        let session = MCSession(
            peer: localPeerId,
            securityIdentity: nil,
            encryptionPreference: .required
        )
        session.delegate = self
        self.session = session

        let browser = MCNearbyServiceBrowser(
            peer: localPeerId,
            serviceType: MultipeerSyncService.serviceType
        )
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.browser = browser
    }

    func stop() {
        keepBrowsingAlive = false
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        reconnectTasks.values.forEach { $0.cancel() }
        reconnectTasks.removeAll()
        browser?.stopBrowsingForPeers()
        browser = nil
        session?.disconnect()
        session = nil
        pendingCode = nil
        pendingFirstParty = false
        targetPeer = nil
        discoveredDevices = []
        connectedPeerNames = []
        if case .error = status { return }
        status = .idle
    }

    func pair(with code: String, to peer: MCPeerID) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy(\.isNumber) else {
            status = .error("Enter the six-digit code shown on the iPad.")
            return
        }
        keepBrowsingAlive = false
        pendingCode = trimmed
        pendingFirstParty = false
        targetPeer = peer
        selectedDeviceID = peer.displayName
        invite(peer: peer, reason: .manualCode)
    }

    func pairWithSelectedOrFirst(code: String) {
        startBrowsing()
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingCode = trimmed
        pendingFirstParty = false
        guard trimmed.count == 6 else {
            status = .error("Enter the six-digit code shown on the iPad.")
            return
        }
        if let id = selectedDeviceID,
           let device = discoveredDevices.first(where: { $0.id == id }) {
            pair(with: trimmed, to: device.peer)
            return
        }
        guard let device = discoveredDevices.first else {
            status = .browsing
            return
        }
        pair(with: trimmed, to: device.peer)
    }

    /// Same Apple ID — pair without a code when household hashes match.
    func pairFirstParty(with peer: MCPeerID) {
        keepBrowsingAlive = true
        pendingCode = nil
        pendingFirstParty = true
        targetPeer = peer
        selectedDeviceID = peer.displayName
        invite(peer: peer, reason: .firstParty)
    }

    func broadcastNotebookChanged(notebookId: UUID) {
        guard let session else { return }
        for peer in session.connectedPeers {
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else { continue }
            MultipeerNotebookHint.send(notebookId: notebookId, to: peer, session: session, key: key)
        }
    }

    func isPeerConnected(_ name: String) -> Bool {
        connectedPeerNames.contains(name)
    }

    /// Send a pre-built signed payload over the browse session.
    /// Mirror of `MultipeerSyncService.sendPayload` — the share
    /// facade tries both sessions since a peer may be connected on
    /// either lane. True means "handed to the transport" (send runs
    /// on `MultipeerSendQueue`, never the main thread).
    func sendPayload(_ payload: Data, toPeerNamed name: String) -> Bool {
        guard let session,
              let peer = session.connectedPeers.first(where: { $0.displayName == name })
        else { return false }
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
        return true
    }

    private enum InviteReason {
        case manualCode
        case firstParty
        case reconnect
    }

    private func invite(peer: MCPeerID, reason: InviteReason) {
        ensureBrowsing()
        status = .connecting(peerName: peer.displayName)
        guard let session else { return }
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 30)
        if reason != .reconnect {
            schedulePairingTimeout(peerName: peer.displayName)
        }
    }

    private func schedulePairingTimeout(peerName: String) {
        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            await MainActor.run {
                guard let self, case .connecting = self.status else { return }
                self.status = .error(
                    "No response from \(peerName). Confirm receive on local network is on for the other device."
                )
            }
        }
    }

    private func scheduleReconnect(to peer: MCPeerID) {
        guard keepBrowsingAlive || MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) != nil else {
            return
        }
        reconnectTasks[peer.displayName]?.cancel()
        reconnectTasks[peer.displayName] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                guard let self else { return }
                guard self.session?.connectedPeers.contains(peer) != true else { return }
                self.invite(peer: peer, reason: .reconnect)
            }
        }
    }

    private func sendPairingHello(to peer: MCPeerID, key: SymmetricKey) {
        guard let session else { return }
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        var header: [String: Any] = [
            "type": "pairing-hello",
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        // Additive v2.1: identify our household so the receiver can
        // tell same-account pairings from cross-account ones.
        if let hash = MultipeerPairingStore.householdTokenHash() {
            header["householdHash"] = hash
        }
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: headerData, using: key))
        var payload = Data()
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
    }

    private func pairingKey(for peer: MCPeerID) -> SymmetricKey? {
        if let code = pendingCode {
            return MultipeerPairingStore.derivedKey(
                fromCode: code,
                localPeerName: localPeerId.displayName,
                remotePeerName: peer.displayName
            )
        }
        if pendingFirstParty {
            return MultipeerPairingStore.derivedFirstPartyKey(
                localPeerName: localPeerId.displayName,
                remotePeerName: peer.displayName
            )
        }
        return MultipeerPairingStore.sharedKey(forPeerName: peer.displayName)
    }

    private func handleIncoming(_ data: Data, from peer: MCPeerID) {
        guard data.count > 4 + 32 else { return }
        let headerLen = Int(UInt32(bigEndian: data.prefix(4).withUnsafeBytes { $0.load(as: UInt32.self) }))
        guard data.count >= 4 + headerLen + 32 else { return }
        let headerData = data.subdata(in: 4..<(4 + headerLen))
        let hmacBytes = data.subdata(in: (4 + headerLen)..<(4 + headerLen + 32))
        let bodyData = data.subdata(in: (4 + headerLen + 32)..<data.count)

        struct Header: Decodable {
            let type: String
            let result: String?
            let householdHash: String?
        }
        guard let header = try? JSONDecoder().decode(Header.self, from: headerData)
        else { return }

        if header.type == "notebook-changed" {
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else { return }
            let signed = headerData + bodyData
            let computed = Data(HMAC<SHA256>.authenticationCode(for: signed, using: key))
            guard hmacBytes == computed,
                  let notebookId = MultipeerNotebookHint.notebookId(from: bodyData)
            else { return }
            NotificationCenter.default.post(
                name: MultipeerNotebookHint.changedNotification,
                object: nil,
                userInfo: ["notebookId": notebookId]
            )
            return
        }

        guard header.type == "pairing-result" else { return }
        guard let key = pairingKey(for: peer) else { return }

        if header.result == "ok" {
            let computed = Data(HMAC<SHA256>.authenticationCode(for: headerData, using: key))
            guard hmacBytes == computed else {
                status = .error("Pairing response failed verification.")
                return
            }
            MultipeerPairingStore.store(key: key, forPeerName: peer.displayName)
            MultipeerNotebookShare.recordHouseholdHash(
                header.householdHash,
                forPeerName: peer.displayName
            )
            MultipeerSyncService.shared.reloadPairedPeers()
            pendingCode = nil
            pendingFirstParty = false
            pairingTimeoutTask?.cancel()
            pairingTimeoutTask = nil
            status = .paired(peerName: peer.displayName)
            keepBrowsingAlive = true
            return
        }

        pairingTimeoutTask?.cancel()
        pairingTimeoutTask = nil
        switch header.result {
        case "wrong_code":
            status = .error("Wrong pairing code — check the digits on the iPad and try again.")
        case "no_pairing_window":
            status = .error("Pairing window closed on the iPad — tap show pairing code again.")
        default:
            status = .error("Pairing failed (\(header.result ?? "unknown")).")
        }
    }

    private func refreshConnectedPeerNames() {
        connectedPeerNames = session?.connectedPeers.map(\.displayName).sorted() ?? []
    }

    private func considerAutoConnect(to peer: MCPeerID, info: [String: String]?) {
        if MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) != nil {
            if session?.connectedPeers.contains(peer) != true, targetPeer == nil || targetPeer == peer {
                invite(peer: peer, reason: .reconnect)
            }
            return
        }

        let remoteHash = info?["householdHash"]
        let localHash = MultipeerPairingStore.householdTokenHash()
        if pendingCode == nil,
           let remoteHash, let localHash, remoteHash == localHash,
           targetPeer == nil || targetPeer == peer {
            pairFirstParty(with: peer)
        }
    }
}

extension MultipeerSendService: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        foundPeer peerID: MCPeerID,
        withDiscoveryInfo info: [String: String]?
    ) {
        guard info?["app"] == "ceciliasnotes" else { return }
        let platform = info?["platform"] ?? "unknown"
        let householdHash = info?["householdHash"]
        Task { @MainActor [weak self] in
            guard let self else { return }
            let device = DiscoveredDevice(
                peer: peerID,
                platform: platform,
                householdHash: householdHash
            )
            // Keep the household record fresh for peers we already
            // trust — pairings older than the hash exchange learn
            // their household this way, without re-pairing.
            if MultipeerPairingStore.sharedKey(forPeerName: peerID.displayName) != nil {
                MultipeerNotebookShare.recordHouseholdHash(
                    householdHash,
                    forPeerName: peerID.displayName
                )
            }
            if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
                discoveredDevices[index] = device
            } else {
                discoveredDevices.append(device)
            }
            if selectedDeviceID == nil {
                selectedDeviceID = device.id
            }
            if let code = pendingCode, targetPeer == nil, case .browsing = status {
                pair(with: code, to: device.peer)
                return
            }
            considerAutoConnect(to: peerID, info: info)
        }
    }

    nonisolated func browser(
        _ browser: MCNearbyServiceBrowser,
        lostPeer peerID: MCPeerID
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            discoveredDevices.removeAll { $0.id == peerID.displayName }
            if selectedDeviceID == peerID.displayName {
                selectedDeviceID = discoveredDevices.first?.id
            }
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in
            self?.status = .error(error.localizedDescription)
        }
    }
}

extension MultipeerSendService: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch state {
            case .connected:
                self.refreshConnectedPeerNames()
                if let key = self.pairingKey(for: peerID),
                   self.pendingCode != nil || self.pendingFirstParty {
                    self.sendPairingHello(to: peerID, key: key)
                } else if MultipeerPairingStore.sharedKey(forPeerName: peerID.displayName) != nil {
                    self.pairingTimeoutTask?.cancel()
                    self.status = .paired(peerName: peerID.displayName)
                }
            case .notConnected:
                self.refreshConnectedPeerNames()
                if MultipeerPairingStore.sharedKey(forPeerName: peerID.displayName) != nil {
                    self.status = .paired(peerName: peerID.displayName)
                    self.scheduleReconnect(to: peerID)
                } else if case .connecting = self.status {
                    self.status = .error("Couldn't connect to \(peerID.displayName).")
                }
            default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            self?.handleIncoming(data, from: peerID)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

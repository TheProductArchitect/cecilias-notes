import Combine
import CryptoKit
import Foundation
@preconcurrency import MultipeerConnectivity
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    /// Info.plist `NSBonjourServices` entry (`_cn-sync._tcp`).
    ///
    /// MultipeerConnectivity enforces a 15-character ceiling on
    /// `serviceType` — the earlier `ceciliasnotes-sync` (18 chars)
    /// threw `NSInvalidArgumentException` on `MCNearbyServiceBrowser`
    /// init on the Mac side. `cn-sync` is the renamed value;
    /// safe because multipeer hadn't shipped to the Mac yet so
    /// there's no transition window to maintain.
    static let serviceType = "cn-sync"

    /// How long a freshly-generated pairing code remains valid.
    static let pairingModeWindow: TimeInterval = 90

    /// Replay window — any payload with a timestamp older than this
    /// is rejected even if the HMAC is valid. Internal (not private)
    /// because the browse lane (`MultipeerSendService`) applies the
    /// same window to `"file"` payloads — one constant, two lanes.
    static let replayWindow: TimeInterval = 60
    /// Defence-in-depth cap on `recentNonces`. The window prune is
    /// the primary mechanism; this guards against a flood of
    /// fresh-nonce probes spiking memory inside a single 60-second
    /// window. 2000 entries is comfortably above any legitimate
    /// send rate (Mac MCP sends one payload per notebook write).
    /// Shared with the browse lane like `replayWindow`.
    static let maxRecentNonces: Int = 2000

    /// User-visible status. Drives Settings caption + status line.
    enum Status: Equatable {
        case off
        case idle                       // advertising, no peers
        case pairing(code: String, expiresAt: Date)
        case connected(peerName: String)
        case receiving(peerName: String)
        case received(peerName: String, filename: String)
        case error(String)

        var peerName: String? {
            switch self {
            case .connected(let name), .receiving(let name), .received(let name, _):
                return name
            default:
                return nil
            }
        }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var isEnabled: Bool = false
    @Published private(set) var pairedPeerNames: [String] = []
    @Published private(set) var connectedPeerNames: [String] = []

    // MARK: Storage keys

    private static let enabledKey = "ceciliasnotes.multipeer.enabled"

    // MARK: Private state

    private let localPeerId: MCPeerID = {
        // Cross-platform device name. `MCPeerID` truncates internally
        // if the display name is >63 UTF-8 bytes, so we cap at 60 to
        // keep multi-byte hostnames safe.
        #if canImport(UIKit)
        let deviceName = UIDevice.current.name
        #else
        // AppKit path — Host.current().localizedName is the friendly
        // "Venu's MacBook Air" string a user recognises in Finder,
        // AirDrop, and Universal Control. Falls back to ProcessInfo
        // hostName if the localized name is unavailable (unlikely on
        // production Macs but cheap to guard).
        let deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        #endif
        let safe = String(deviceName.prefix(60))
        return MCPeerID(displayName: safe)
    }()

    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?

    /// Active pairing window. nil unless the user has tapped
    /// "show pairing code" within the last `pairingModeWindow`.
    private var activePairingCode: String?
    private var pairingExpiresAt: Date?

    /// Wrong-code hellos seen during the current pairing window.
    /// The nonce/timestamp checks don't slow an attacker down (they
    /// control both fields), so without this cap a LAN peer could
    /// spray candidate-code HMACs and brute-force the 6-digit space
    /// inside the 90-second window. A handful of failures closes
    /// the window; the legitimate user just taps "show pairing
    /// code" again.
    private var pairingFailedAttempts = 0
    private static let maxPairingFailedAttempts = 5

    /// Nonces seen in the replay window. Trimmed on every receive.
    private var recentNonces: [(nonce: String, seenAt: Date)] = []

    private override init() {
        super.init()
        // Default ON: same-Apple-Account devices should find each
        // other with zero setup (auto-pair is gated on the iCloud
        // household key; strangers still need the 6-digit code).
        // Users who explicitly turned receive off stay off.
        self.isEnabled = UserDefaults.standard
            .object(forKey: Self.enabledKey) as? Bool ?? true
        refreshPairedPeerNames()
        if isEnabled { start() }
    }

    // MARK: Public API

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        isEnabled = enabled
        if enabled {
            start()
            // Resume the browse/reconnect lane too, but only when there
            // is actually something to look for — otherwise leave it
            // dormant (matches the launch gate in CeciliasNotesApp).
            if !MultipeerPairingStore.pairedPeerNames().isEmpty
                || MultipeerPairingStore.householdTokenHash() != nil {
                MultipeerSendService.shared.startBackgroundReconnect()
            }
        } else {
            stop()
            // Definitively silence the browse lane: cancels every
            // pending reconnect task, stops the browser, disconnects
            // the session. This is what stops the DTLS "No route to
            // host" storm when a paired device is unreachable.
            MultipeerSendService.shared.stop()
        }
    }

    /// Enter pairing mode for the next `pairingModeWindow` seconds.
    /// Returns the displayed 6-digit code so the UI can render it.
    @discardableResult
    func beginPairing() -> String {
        let code = MultipeerPairingStore.generatePairingCode()
        let expiry = Date().addingTimeInterval(Self.pairingModeWindow)
        activePairingCode = code
        pairingExpiresAt = expiry
        pairingFailedAttempts = 0
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

    /// Reload paired peer names from Keychain (e.g. after Mac-side pairing).
    func reloadPairedPeers() {
        refreshPairedPeerNames()
    }

    /// Notify paired, connected peers that a notebook changed so they
    /// can refresh immediately while both apps are in the foreground.
    func broadcastNotebookChanged(notebookId: UUID) {
        guard isEnabled, let session else { return }
        for peer in session.connectedPeers {
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else { continue }
            MultipeerNotebookHint.send(notebookId: notebookId, to: peer, session: session, key: key)
        }
    }

    /// Send a pre-built signed payload to a connected peer over the
    /// receiver session. Returns false when the peer isn't connected
    /// on this session (the caller can then try the browse session).
    /// True means "handed to the transport", not "delivered" — the
    /// send runs on `MultipeerSendQueue` (a `.reliable` send of a
    /// multi-MB file on the main thread is an ANR when the link is
    /// degrading), and iCloud remains the durable path if it drops.
    func sendPayload(_ payload: Data, toPeerNamed name: String) -> Bool {
        guard let session,
              let peer = session.connectedPeers.first(where: { $0.displayName == name })
        else { return false }
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
        return true
    }

    func isPeerConnected(_ name: String) -> Bool {
        connectedPeerNames.contains(name)
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

        // Discovery info carries a `householdHash` when this
        // device has an iCloud-Keychain-synced household key.
        // Same-Apple-ID peers see a matching hash and skip the
        // 6-digit code in the pairing-hello handler. Mac MCP
        // (different Apple-ID hash, or no household key) still
        // routes through the manual flow.
        var discoveryInfo: [String: String] = [
            "app": "ceciliasnotes",
            "v": "2"
        ]
        if let hash = MultipeerPairingStore.householdTokenHash() {
            discoveryInfo["householdHash"] = hash
        }
        #if os(macOS)
        discoveryInfo["platform"] = "macos"
        #else
        discoveryInfo["platform"] = "ios"
        #endif
        let advertiser = MCNearbyServiceAdvertiser(
            peer: localPeerId,
            discoveryInfo: discoveryInfo,
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

    private func refreshConnectedPeerNames() {
        connectedPeerNames = session?.connectedPeers.map(\.displayName).sorted() ?? []
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
    ///   "type": "file" | "notebook-changed" | "live-ink" | "ping"
    ///         | "pairing-hello",       // this lane; replies use
    ///                                  // "pong" / "pairing-result"
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
            /// Sender's household token hash (additive, v2.1) — lets
            /// the receiver tell "same Apple Account" pairings apart
            /// from cross-account ones in Settings and share UI.
            let householdHash: String?
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
        // Nonce de-dupe. Primary defence is the time-window prune;
        // the hard cap below is defence-in-depth so a flood of
        // unique-nonce probes from a hostile peer (each within the
        // replay window) can't grow the array without bound before
        // the window prune catches them.
        let nowMinusWindow = Date().addingTimeInterval(-Self.replayWindow)
        recentNonces.removeAll { $0.seenAt < nowMinusWindow }
        if recentNonces.count >= Self.maxRecentNonces {
            recentNonces.removeFirst(recentNonces.count - Self.maxRecentNonces / 2)
        }
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

        case "notebook-changed":
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else { return }
            guard verifyHMAC(hmacBytes, message: signedRange, key: key) else { return }
            recentNonces.append((header.nonce, Date()))
            if let notebookId = MultipeerNotebookHint.notebookId(from: bodyData) {
                NotificationCenter.default.post(
                    name: MultipeerNotebookHint.changedNotification,
                    object: nil,
                    userInfo: ["notebookId": notebookId]
                )
                status = .connected(peerName: peer.displayName)
            }

        case "live-ink":
            // Ephemeral drawing snapshot (protocol v2.4). Same-
            // household only on the SEND side; the receive side just
            // requires a paired key — the editor decides whether the
            // notebook is open and drops it otherwise. Never touches
            // SwiftData: the canvas renders it as a transient overlay
            // and CloudKit delivers the durable rows.
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else { return }
            guard verifyHMAC(hmacBytes, message: signedRange, key: key) else { return }
            recentNonces.append((header.nonce, Date()))
            if let parsed = MultipeerLiveInk.parseBody(bodyData) {
                NotificationCenter.default.post(
                    name: MultipeerLiveInk.receivedNotification,
                    object: nil,
                    userInfo: [
                        MultipeerLiveInk.UserInfoKey.notebookId: parsed.notebookId,
                        MultipeerLiveInk.UserInfoKey.pageId: parsed.pageId,
                        MultipeerLiveInk.UserInfoKey.seq: parsed.seq,
                        MultipeerLiveInk.UserInfoKey.drawingData: parsed.drawingData,
                    ]
                )
            }

        case "ping":
            // Liveness probe — sender uses this to detect a
            // half-broken session before committing to a full file
            // transfer. We HMAC-verify the ping with the paired key
            // (rejecting unpaired peers), then reply with a `pong`
            // signed by the same key. Senders without the right
            // key get nothing back and time out fast.
            guard let key = MultipeerPairingStore.sharedKey(forPeerName: peer.displayName) else {
                // Silent drop — don't leak "we don't know you" via
                // a status string when an attacker is probing.
                return
            }
            guard verifyHMAC(hmacBytes, message: signedRange, key: key) else {
                return
            }
            recentNonces.append((header.nonce, Date()))
            sendPong(to: peer, key: key)

        case "pairing-hello":
            // Two acceptable paths:
            //   1. First-party auto-pair: HMAC verifies against
            //      the iCloud-Keychain-synced household key
            //      (same Apple ID on both sides). No 6-digit code,
            //      no pairing window required.
            //   2. Manual code: HMAC verifies against the key
            //      derived from the active pairing code. Pairing
            //      mode must be open.
            // Always reply with a `pairing-result` so the Mac can
            // distinguish failure modes instead of timing out.

            if let firstPartyKey = MultipeerPairingStore.derivedFirstPartyKey(
                localPeerName: localPeerId.displayName,
                remotePeerName: peer.displayName
            ), verifyHMAC(hmacBytes, message: signedRange, key: firstPartyKey) {
                // First-party auto-pair succeeded.
                recentNonces.append((header.nonce, Date()))
                MultipeerPairingStore.store(key: firstPartyKey, forPeerName: peer.displayName)
                // Verified against OUR household derivation → same account.
                MultipeerNotebookShare.recordHouseholdHash(
                    MultipeerPairingStore.householdTokenHash(),
                    forPeerName: peer.displayName
                )
                refreshPairedPeerNames()
                status = .connected(peerName: peer.displayName)
                sendPairingResult(result: "ok", to: peer, key: firstPartyKey)
                return
            }

            guard let code = activePairingCode,
                  let expiresAt = pairingExpiresAt,
                  Date() < expiresAt
            else {
                sendPairingResult(result: "no_pairing_window", to: peer, key: nil)
                status = .error("\(peer.displayName) tried to pair, but pairing mode isn't on")
                return
            }
            let candidate = MultipeerPairingStore.derivedKey(
                fromCode: code,
                localPeerName: localPeerId.displayName,
                remotePeerName: peer.displayName
            )
            guard verifyHMAC(hmacBytes, message: signedRange, key: candidate) else {
                pairingFailedAttempts += 1
                if pairingFailedAttempts >= Self.maxPairingFailedAttempts {
                    activePairingCode = nil
                    pairingExpiresAt = nil
                    sendPairingResult(result: "no_pairing_window", to: peer, key: nil)
                    status = .error("Too many wrong pairing codes — pairing closed. Show a new code to retry.")
                    return
                }
                sendPairingResult(result: "wrong_code", to: peer, key: nil)
                status = .error("Wrong pairing code from \(peer.displayName) — try again")
                return
            }
            recentNonces.append((header.nonce, Date()))
            MultipeerPairingStore.store(key: candidate, forPeerName: peer.displayName)
            // Manual-code pairing — remember the sender's household
            // hash (when provided) so Settings can say whether this
            // peer shares our Apple Account or needs Send to Device.
            MultipeerNotebookShare.recordHouseholdHash(
                header.householdHash,
                forPeerName: peer.displayName
            )
            refreshPairedPeerNames()
            // Pairing succeeded → exit pairing mode immediately so a
            // second attacker on the LAN can't reuse the window.
            activePairingCode = nil
            pairingExpiresAt = nil
            status = .connected(peerName: peer.displayName)
            sendPairingResult(result: "ok", to: peer, key: candidate)

        default:
            // Protocol rule: unknown types are IGNORED (see
            // MULTIPEER_SYNC_PROTOCOL.md — the sidecar already does).
            // Painting an error status here turned every protocol
            // addition into a user-visible "Unknown payload type"
            // scare on devices still running the older build — v2.4's
            // live-ink did exactly that to 3.0(3). A quiet drop costs
            // nothing: the payload is either from a newer version
            // (fine) or noise the HMAC layer never blessed (also fine).
            #if DEBUG
            dlog("[Multipeer] ignoring unknown payload type \"\(header.type)\" from \(peer.displayName)")
            #endif
            break
        }
    }

    /// Reply to a `pairing-hello` with a typed result so the Mac
    /// can show the user the right error message.
    ///
    /// - `key` non-nil → success path. Body carries
    ///   `{"result": "ok"}`, HMAC computed with the derived key.
    ///   Mac verifies → confirmed pairing.
    /// - `key` nil → informational hint. Body carries
    ///   `{"result": "wrong_code" | "no_pairing_window"}`, HMAC
    ///   field is 32 zero bytes. Mac treats as a typed hint with
    ///   no security guarantee — useful for UX feedback only.
    ///   An attacker spoofing this reply only causes the user to
    ///   retry, which is not a compromise.
    private func sendPairingResult(result: String, to peer: MCPeerID, key: SymmetricKey?) {
        guard let session else { return }
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        var header: [String: Any] = [
            "type": "pairing-result",
            "result": result,
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        // Additive v2.1: tell the successful sender which household
        // we belong to, so both sides can distinguish same-account
        // sync pairs from cross-account share pairs.
        if result == "ok", let hash = MultipeerPairingStore.householdTokenHash() {
            header["householdHash"] = hash
        }
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }
        let tag: Data
        if let key {
            tag = Data(HMAC<SHA256>.authenticationCode(for: headerData, using: key))
        } else {
            tag = Data(count: 32) // all zeros — "unsigned hint"
        }
        var payload = Data()
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
    }

    /// Build and send a `pong` reply HMAC-signed with the same key
    /// the ping was verified against. Empty body. Errors are
    /// swallowed — a failed pong just causes the sender to time
    /// out and fall back to iCloud, which is the correct behaviour.
    private func sendPong(to peer: MCPeerID, key: SymmetricKey) {
        guard let session else { return }
        let nonce = Data((0..<16).map { _ in UInt8.random(in: 0...UInt8.max) })
        let header: [String: Any] = [
            "type": "pong",
            "timestamp": Int(Date().timeIntervalSince1970),
            "nonce": nonce.base64EncodedString()
        ]
        guard let headerData = try? JSONSerialization.data(withJSONObject: header) else { return }
        let tag = Data(HMAC<SHA256>.authenticationCode(for: headerData, using: key))
        var payload = Data()
        var lenBE = UInt32(headerData.count).bigEndian
        payload.append(Data(bytes: &lenBE, count: 4))
        payload.append(headerData)
        payload.append(tag)
        MultipeerSendQueue.enqueue(payload, to: peer, session: session)
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

    /// Browse-lane hand-off. A `"file"` payload can arrive on EITHER
    /// end of either session — which lane it lands on depends on who
    /// invited whom (both devices run an advertiser AND a browser),
    /// not on who is sending the file. `MultipeerSendService` verifies
    /// key + HMAC + replay, then routes here so the inbox write and
    /// the user-visible received/error status live in one place.
    func receiveVerifiedFile(filename: String?, body: Data, peer: MCPeerID) {
        writeFileToInbox(filename: filename, body: body, peer: peer)
    }

    private func writeFileToInbox(filename: String?, body: Data, peer: MCPeerID) {
        guard body.count <= CeciliasNotesParser.maxFileBytes else {
            status = .error("File from \(peer.displayName) too large — rejected")
            return
        }
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
        // `.ceciliabook` is the full-fidelity archive "Send to
        // Device" transmits — stripping it to `.inkbook` here routed
        // the archive to the text-mirror importer, which can't read
        // it. The extension decides which importer runs, so it must
        // survive sanitisation.
        let allowed = ["inkbook", "json", NotebookArchive.fileExtension]
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
                self.refreshConnectedPeerNames()
                if case .pairing = self.status {
                    break
                } else {
                    self.status = .connected(peerName: peerID.displayName)
                }
            case .notConnected:
                self.refreshConnectedPeerNames()
                if self.status.peerName == peerID.displayName {
                    self.status = .idle
                }
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
        // The handler type is fixed by Apple's MC delegate API and
        // isn't Sendable, but we still need to hop to MainActor to
        // read `self.session`. Wrap the handler in an unchecked
        // Sendable box so the Task closure can capture it; the
        // handler runs exactly once on the main actor, which matches
        // MC's expected single-shot semantics.
        let handlerBox = UncheckedSendableBox(invitationHandler)
        Task { @MainActor [weak self] in
            guard let self, let session = self.session else {
                handlerBox.value(false, nil)
                return
            }
            // Accept the MC-level invitation unconditionally — the
            // HMAC layer above rejects anything not from a paired
            // (or pairing-mode-authorised) peer. Refusing here would
            // break the legitimate pairing handshake before the first
            // payload arrives.
            handlerBox.value(true, session)
        }
    }
}

// MARK: - Sendable transfer helper

/// Single-shot box for ferrying a non-Sendable callback into a
/// `Task { @MainActor in … }` closure. Apple's MC delegate hands us
/// a non-Sendable `(Bool, MCSession?) -> Void` handler that we must
/// call after a main-actor hop; this box lets the Task capture the
/// closure without Swift 6 complaining about cross-actor sending.
/// The handler is invoked exactly once per delegate callback, so
/// "unchecked" is sound here.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    nonisolated(unsafe) let value: T
    nonisolated init(_ value: T) { self.value = value }
}

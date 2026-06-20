# Multipeer Sync — Wire Protocol (v2 — authenticated)

Direct device-to-device notebook delivery from a Mac running
`cecilias-notes-mcp` to an iPad running Cecilia's Notes, bypassing
iCloud's sync latency. Mac and iPad must be on the same Wi-Fi or
Bluetooth-PAN.

**Security**: every payload is HMAC-SHA256 authenticated with a
per-peer shared key derived from a one-time pairing code. Peer-name
spoofing on the LAN is rejected at the HMAC layer.

iPad implementation: `Core/Services/MultipeerSyncService.swift` +
`Core/Services/MultipeerPairingStore.swift`.

---

## Transport

MultipeerConnectivity over Wi-Fi peer-to-peer + Bluetooth PAN. TLS
enforced via `MCSession.encryptionPreference = .required` (handles
link-layer encryption; the HMAC layer is what protects against a
peer-name-spoofing attacker who *also* establishes a session).

## Discovery

- **Service type**: `ceciliasnotes-sync`
- **Bonjour name**: `_ceciliasnotes-sync._tcp` (listed in the iPad's
  Info.plist `NSBonjourServices`).
- iPad **advertises** with `MCNearbyServiceAdvertiser`,
  `discoveryInfo = {"app": "ceciliasnotes", "platform": "ios", "v": "2"}`.
- Mac MCP **browses** with `MCNearbyServiceBrowser` for the same
  service type, sends `invitePeer(...)` to start a session.

## Pairing flow

First-time pairing is a separate, human-authorised step before any
file payloads are accepted.

### iPad side

1. User taps **Settings → cloud → show pairing code**.
2. iPad generates a cryptographically-random 6-digit code, displays
   it on screen, and enters "pairing mode" for **90 seconds**.

### Mac side

3. Mac prompts the user: "Enter the 6-digit code shown on the iPad".
4. User types the code into the Mac MCP CLI / GUI.
5. Mac derives a 32-byte shared key via HKDF (see below).
6. Mac sends a `pairing-hello` payload HMAC-signed with the derived
   key.

### Both sides

7. iPad recomputes the HMAC with its own derived key. If they match
   → pairing succeeds, the iPad stores the key in Keychain under
   the Mac's peer name, and pairing mode is exited. If they don't
   match → payload is dropped and pairing mode stays open for a
   second attempt within the 90s window.

### Key derivation (HKDF-SHA256)

Both sides MUST use identical inputs:

- **Input key material**: the 6-digit code as raw UTF-8 bytes.
- **Salt**: `"ceciliasnotes.multipeer.v1.salt"` as UTF-8.
- **Info**: `"<localPeerName>|<remotePeerName>"` as UTF-8, where:
  - On the iPad: `localPeerName` is the iPad's `MCPeerID.displayName`
    (typically the iPad's name from Settings → General → About).
    `remotePeerName` is the Mac's peer name.
  - On the Mac: the roles flip — `localPeerName` is the Mac's peer
    name, `remotePeerName` is the iPad's.
- **Output**: 32 bytes.

Because the info string includes both peer names, the same code
typed for different device pairs produces different keys.

## Payload format (v2)

A single binary blob sent via
`MCSession.send(_:toPeers:with:.reliable)`:

```
+--------+----------+----------+----------+
| 4 byte | header   | hmac     | body     |
| BE u32 | JSON     | 32 bytes | rest     |
+--------+----------+----------+----------+
```

- **Bytes 0–3**: big-endian uint32, length of the JSON header in
  bytes.
- **Bytes 4 .. 4+H-1**: UTF-8 JSON header (see schema below).
- **Bytes 4+H .. 4+H+31**: HMAC-SHA256 tag.
- **Bytes 4+H+32 ..**: payload body.

### Header schema

```json
{
  "type": "file" | "pairing-hello" | "ping" | "pong",
  "filename": "Sketchbook.inkbook",
  "timestamp": 1718817100,
  "nonce": "<base64-16-bytes>"
}
```

- `type` is required:
  - `"file"` — notebook delivery
  - `"pairing-hello"` — pairing handshake
  - `"ping"` — liveness probe sent by the Mac before a file payload
  - `"pong"` — iPad's reply to a `ping`
- `filename` is required when `type == "file"`. iPad strips path
  separators and rejects extensions other than `.inkbook` / `.json`.
- `timestamp` is epoch seconds. Payloads outside a ±60 second window
  from the iPad's current time are rejected (replay protection).
- `nonce` is a 16-byte cryptographically-random value, base64-encoded.
  iPad keeps a sliding window of seen nonces; a duplicate is rejected.

### HMAC

`HMAC-SHA256(key, headerJSON || body)`.

The key is whichever key applies:
- For `type == "file"`: the stored key for the sender's peer name.
  If no stored key exists, the payload is dropped — the peer must
  pair first.
- For `type == "pairing-hello"`: the candidate key derived from the
  active pairing code. Only one payload at a time can succeed
  here, and only while the iPad is in pairing mode.

### Body

- For `type == "file"`: raw file bytes (the `.inkbook` blob itself).
- For `type == "pairing-hello"`: empty (zero bytes). Pairing
  succeeds based on the HMAC match alone — no payload necessary.
- For `type == "ping"` and `type == "pong"`: empty (zero bytes).

## Ping / pong (liveness probe)

MultipeerConnectivity reports a session as `.connected` based on the
underlying socket handshake, but it's slow to surface "the peer is
connected but the link is dead" (radio went out of range, the iPad
got force-quit mid-session, etc.). For multi-second file transfers
that's a problem — the Mac sender will block on `session.send`
until MC eventually times out.

**Solution**: the Mac sender issues a `ping` immediately after the
session reaches `.connected`. If a `pong` doesn't arrive within
500ms, the sender aborts and falls back to iCloud Inbox writes. A
healthy session round-trips in 20–80ms over Bluetooth-PAN and
under 20ms over Wi-Fi peer-to-peer, so 500ms is comfortable
headroom with zero false positives in practice.

### Mac side

1. Wait for `MCSession.state == .connected`.
2. Build a `ping` payload (HMAC-signed with the stored shared key).
3. Send it; start a 500ms timer.
4. Wait for `session(_:didReceive:)` to deliver a `pong` HMAC-signed
   with the same key. Cancel the timer.
5. If the timer fires first, call `session.disconnect()` and fall
   through to the iCloud-only path.

### iPad side

1. Receive `ping`, verify HMAC against the stored key for the
   sender. Drop silently on miss (don't leak status info to an
   attacker probing the network).
2. Send a `pong` HMAC-signed with the same key. Empty body. Fresh
   timestamp + nonce.

### Failure modes

- **`pong` never arrives**: peer is unreachable. Disconnect, log
  reason, write to iCloud.
- **`pong` arrives but HMAC fails**: someone else on the network
  is impersonating the iPad. Disconnect, do NOT retry.
- **`pong` arrives outside the timestamp window**: clocks are
  drifting. Disconnect, surface the skew in the Mac's logs.

## What the iPad does on success

iPad writes the body to the iCloud inbox folder (the same path
`CeciliasNotesFileWatcher` polls) and immediately calls `rescan()`
so the importer runs in milliseconds rather than waiting for the
next NSMetadataQuery DidUpdate. The same file will also propagate
via iCloud's usual sync; the importer is idempotent on content hash
so the duplicate is a no-op.

## Failure modes the Mac side should handle

- **Pairing window expired** → user has to re-tap "show pairing
  code" on the iPad and retry. iPad surface a transient error in
  its status.
- **HMAC mismatch** → iPad reports `"Wrong pairing code from <Mac>"`.
  Mac should treat this as "wrong code typed; ask user again".
- **Stale timestamp** → iPad reports `"Stale payload"`. Mac's
  clock is more than 60 seconds off the iPad's; check NTP.
- **Replay nonce** → iPad reports `"Replay detected"`. Mac should
  never resend a payload with the same nonce; generate fresh
  random per send.
- **Unpaired peer** → iPad reports `"Unpaired peer X — payload
  rejected"`. Mac is sending file payloads before completing
  pairing. Run the pairing handshake first.

## Status states the iPad reports

`MultipeerSyncService.status` is `@Published`. Settings displays:

- `.off` — toggle disabled
- `.idle` — advertising, no peers connected
- `.pairing(code:, expiresAt:)` — pairing window open
- `.connected(peerName:)` — session up
- `.receiving(peerName:)` — payload in flight
- `.received(peerName:, filename:)` — success
- `.error(String)` — transient failure (see above)

## Example sender code (macOS, abridged)

```swift
import CryptoKit
import MultipeerConnectivity

let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
let session = MCSession(peer: peerID, securityIdentity: nil,
                        encryptionPreference: .required)
let browser = MCNearbyServiceBrowser(peer: peerID,
                                     serviceType: "ceciliasnotes-sync")
// browser.delegate, etc.

// ---- Pairing ----
let code = readUserInput("Enter the 6-digit pairing code shown on the iPad: ")
let salt = "ceciliasnotes.multipeer.v1.salt".data(using: .utf8)!
let info = "\(peerID.displayName)|\(iPadPeer.displayName)".data(using: .utf8)!
let inputKey = SymmetricKey(data: code.data(using: .utf8)!)
let sharedKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: inputKey,
    salt: salt,
    info: info,
    outputByteCount: 32
)

let helloHeader: [String: Any] = [
    "type": "pairing-hello",
    "timestamp": Int(Date().timeIntervalSince1970),
    "nonce": randomBase64(16)
]
let headerJSON = try JSONSerialization.data(withJSONObject: helloHeader)
let tag = Data(HMAC<SHA256>.authenticationCode(for: headerJSON, using: sharedKey))

var payload = Data()
var len = UInt32(headerJSON.count).bigEndian
payload.append(Data(bytes: &len, count: 4))
payload.append(headerJSON)
payload.append(tag)
// body is empty for pairing-hello

try session.send(payload, toPeers: [iPadPeer], with: .reliable)

// On success, persist `sharedKey` in macOS Keychain under iPadPeer.displayName
// and use it for every subsequent file send.

// ---- File send ----
let fileHeader: [String: Any] = [
    "type": "file",
    "filename": "Sketchbook.inkbook",
    "timestamp": Int(Date().timeIntervalSince1970),
    "nonce": randomBase64(16)
]
let fhJSON = try JSONSerialization.data(withJSONObject: fileHeader)
let fileBody = try Data(contentsOf: localInkbookURL)
let fileTag = Data(HMAC<SHA256>.authenticationCode(
    for: fhJSON + fileBody, using: sharedKey
))

var fpayload = Data()
var flen = UInt32(fhJSON.count).bigEndian
fpayload.append(Data(bytes: &flen, count: 4))
fpayload.append(fhJSON)
fpayload.append(fileTag)
fpayload.append(fileBody)
try session.send(fpayload, toPeers: [iPadPeer], with: .reliable)
```

---

## Versioning

- Header JSON is the extensibility point. Add new keys; the iPad
  only requires `type`, `timestamp`, `nonce` (+ `filename` for file
  type). Adding `notebookId`, `checksum`, `producer` is
  forward-compatible.
- Bumping the framing format (length prefix + HMAC layout) breaks
  the iPad — to upgrade, introduce a new `serviceType`
  (`ceciliasnotes-sync-v3`) and have the iPad advertise both for a
  transition window.
- Pairing-key versioning is folded into the HKDF salt
  (`ceciliasnotes.multipeer.v1.salt`). Rotating the salt would
  invalidate every existing pairing and force re-pairing.

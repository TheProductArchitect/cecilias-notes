# Multipeer Sync — Wire Protocol (v2.3 — household exchange + hardening)

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

- **Service type**: `cn-sync`
  - MultipeerConnectivity enforces a **15-character ceiling** on
    `serviceType` (Apple's `MCNearbyServiceBrowser` throws
    `NSInvalidArgumentException` above that). The earlier
    `ceciliasnotes-sync` value (18 chars) was unusable; `cn-sync`
    (7 chars) is the synchronised replacement on both sides.
- **Bonjour name**: `_cn-sync._tcp` (listed in the iPad's
  Info.plist `NSBonjourServices`).
- iPad **advertises** with `MCNearbyServiceAdvertiser`,
  `discoveryInfo = {"app": "ceciliasnotes", "platform": "ios", "v": "2"}`.
- Mac MCP **browses** with `MCNearbyServiceBrowser` for the same
  service type, sends `invitePeer(...)` to start a session.

## First-party auto-pairing (v2.2)

When both devices are signed into the same Apple ID, pairing
should be automatic — no 6-digit code dance for your own
iPad / iPhone / Mac.

**Mechanism.** Each device generates (or fetches) a 32-byte
random "household key" stored under
`app.ceciliasnotes.multipeer.householdKey` in **iCloud Keychain**
(`kSecAttrSynchronizable = true`, end-to-end encrypted by Apple).
Every device signed into the same Apple ID converges on the same
key within a few seconds of first launch.

The advertise step includes
`discoveryInfo["householdHash"] = SHA256(householdKey)[0..8].hex` so
a browser can spot a same-household peer without learning the key
itself. When the hashes match, the sender derives its pairing
key via:

- IKM = household key (32 bytes from iCloud Keychain)
- Salt = `"ceciliasnotes.multipeer.v1.firstparty.salt"` (UTF-8)
- Info = `"<localPeerName>|<remotePeerName>"` (UTF-8)
- Output = 32 bytes

…and signs a `pairing-hello` with the result. The iPad receiver
runs the same derivation and accepts the pairing without any
pairing window being open (no 6-digit code required). The
auto-paired key is stored under the peer name in the *local*
Keychain (synchronizable: false) just like a manual pairing.

**Why it's safe.** iCloud Keychain is end-to-end encrypted — the
household key never leaves Apple's E2E envelope. The
`householdHash` in the discovery info is only useful for spotting
same-household peers; reversing it to the key is infeasible (8
bytes of SHA-256 over 32 bytes of CSPRNG output). The HMAC layer
still authenticates every payload, and the per-peer-pair HKDF
binding prevents key reuse across different device pairs.

A Mac MCP running outside the user's Apple-ID environment (or
without iCloud Keychain enabled) won't have the household key →
falls through to the manual code path.

## Pairing flow (manual, for third-party senders)

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

7. iPad recomputes the HMAC with its own derived key, **and replies
   with a typed `pairing-result` payload** (see schema below) so the
   Mac can show the user the right error message instead of just
   timing out on the post-pairing ping.

   - HMAC match → iPad stores the key in Keychain under the Mac's
     peer name, exits pairing mode, and sends
     `pairing-result {result: "ok"}` HMAC-signed with the
     derived key. The Mac MUST verify this HMAC before treating
     the pairing as confirmed.
   - HMAC mismatch (wrong code) → iPad sends
     `pairing-result {result: "wrong_code"}` with an
     **all-zeros HMAC tag** (unsigned hint — see below). Pairing
     mode stays open for a second attempt within the 90s window.
   - No pairing window open → iPad sends
     `pairing-result {result: "no_pairing_window"}` with an
     all-zeros HMAC tag.

### The "unsigned hint" convention

A header with an **all-zero 32-byte HMAC tag** is an *informational
reply*, not an authenticated message. The Mac uses it only to render
the right error UI; it confers no security guarantee. The threat
model holds: an attacker who spoofs a `wrong_code` or
`no_pairing_window` reply can only cause the user to retry, which
isn't a compromise. The Mac MUST NOT treat an all-zero-HMAC payload
as evidence of anything other than "some peer on the LAN said this".

Only `pairing-result` uses this convention. `file`, `ping`, `pong`,
and `pairing-hello` (the success-path `pairing-result` too) all
require a verified HMAC.

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
  "type": "file" | "pairing-hello" | "pairing-result" | "ping" | "pong",
  "filename": "Sketchbook.inkbook",
  "result": "ok" | "wrong_code" | "no_pairing_window",
  "timestamp": 1718817100,
  "nonce": "<base64-16-bytes>"
}
```

- `type` is required:
  - `"file"` — notebook delivery
  - `"pairing-hello"` — pairing handshake (Mac → iPad)
  - `"pairing-result"` — iPad's typed reply to a `pairing-hello`
  - `"ping"` — liveness probe sent by the Mac before a file payload
  - `"pong"` — iPad's reply to a `ping`
- `result` is required when `type == "pairing-result"`. One of
  `"ok"`, `"wrong_code"`, `"no_pairing_window"`. Future values
  MAY be added; the Mac SHOULD treat an unknown value as a
  generic failure.
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
- For `type == "pairing-result"` with `result == "ok"`: the
  derived/stored key — same key the Mac used to sign the
  `pairing-hello`. Verifying this is how the Mac confirms the
  pairing succeeded.
- For `type == "pairing-result"` with `result == "wrong_code"` or
  `"no_pairing_window"`: a 32-byte all-zero tag (the "unsigned
  hint" convention above). The Mac MUST NOT attempt to verify
  these; treat them as UI hints only.

### Body

- For `type == "file"`: raw file bytes (the `.inkbook` blob itself).
- For `type == "pairing-hello"`: empty (zero bytes). Pairing
  succeeds based on the HMAC match alone — no payload necessary.
- For `type == "pairing-result"`: empty (zero bytes). The
  `result` lives in the header.
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

- **Pairing window expired / not open** → iPad replies
  `pairing-result {result: "no_pairing_window"}` (unsigned hint).
  Mac surfaces: "iPad isn't in pairing mode — re-tap *show
  pairing code* on the iPad and try again."
- **Wrong code typed** → iPad replies
  `pairing-result {result: "wrong_code"}` (unsigned hint).
  Mac surfaces: "Wrong pairing code — try again." Pairing mode
  on the iPad stays open until the 90s window elapses.
- **No `pairing-result` arrives at all** → peer crashed, went out
  of range, or is on an old build that doesn't speak v2.1. Mac
  falls back to iCloud and reports `peer_unreachable` (NOT
  `wrong_code` — the previous version had to guess).
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
                                     serviceType: "cn-sync")
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

## Derivation info string — sorted, both flows

BOTH key derivations (6-digit code and first-party household) build
the HKDF info string from the two peer names sorted
lexicographically: `sort(localName, remoteName).join("|")`. The
receiver has always sorted (`MultipeerPairingStore.peerPairInfo`);
sender implementations MUST sort too. (The MCP sidecar ≤2.1.0 used
unsorted `local|remote`, which only matched when the Mac's peer
name happened to sort first — fixed in 2.2.0.)

## v2.3 additions (all additive / optional)

- **`householdHash` in pairing headers.** `pairing-hello` MAY carry
  `"householdHash": "<16-hex-chars>"` (the sender's household token
  hash, same value as the discoveryInfo key). A successful
  `pairing-result {result: "ok"}` MAY carry the receiver's hash
  back. Both sides record the peer's hash so UI can distinguish
  "same Apple Account — notebooks sync via iCloud" from "different
  Apple Account — use Send to Device". Old builds omit/ignore the
  key; nothing breaks.
- **Wrong-code attempt cap.** The receiver closes the pairing
  window after **5** `pairing-hello` payloads that fail HMAC
  verification (reply: `no_pairing_window`). Nonce/timestamp checks
  don't slow a brute-forcer (it controls both fields); the cap
  does. The legitimate user just taps "show pairing code" again.
- **Payload size cap.** `file` payload bodies above **32 MB**
  (`CeciliasNotesParser.maxFileBytes`) are rejected — matching the
  importer's own cap, so an oversized send fails fast at the wire
  instead of silently never importing.
- **Bidirectional browsing.** Every platform now runs both the
  advertiser AND the browser lane (previously only the Mac
  browsed). Two same-household iOS devices form up to two
  independent MCSessions (one per direction); receivers handle
  payloads on both, and duplicate change-hints are harmless.
- **`file` payloads flow both ways.** The in-app "Send to Device"
  feature ships a notebook's `.inkbook` over the paired link from
  ANY platform. The receiver treats it exactly like an MCP write:
  Inbox → importer → merge-by-default.

## Versioning

- Header JSON is the extensibility point. Add new keys; the iPad
  only requires `type`, `timestamp`, `nonce` (+ `filename` for file
  type). Adding `notebookId`, `checksum`, `producer` is
  forward-compatible.
- Bumping the framing format (length prefix + HMAC layout) breaks
  the iPad — to upgrade, introduce a new `serviceType`
  (`cn-sync-v3`, **kept under the 15-char Bonjour ceiling**) and
  have the iPad advertise both for a transition window.
- Pairing-key versioning is folded into the HKDF salt
  (`ceciliasnotes.multipeer.v1.salt`). Rotating the salt would
  invalidate every existing pairing and force re-pairing.

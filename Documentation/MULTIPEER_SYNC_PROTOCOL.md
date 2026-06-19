# Multipeer Sync — Wire Protocol

Spec the Mac MCP side needs to match for direct device-to-device
notebook delivery, sidestepping iCloud's 30 sec – 5 min sync latency.

Implemented on the iPad in
`Core/Services/MultipeerSyncService.swift`. This doc captures the
contract so the macOS sender can be built against it without
re-reading Swift.

---

## Transport

Apple's MultipeerConnectivity framework over Wi-Fi peer-to-peer +
Bluetooth PAN. Encryption is TLS, enforced by setting
`MCSession.encryptionPreference = .required` on the iPad side.

## Discovery

- **Service type**: `ceciliasnotes-sync`
- **Bonjour name** (as listed in iPad's Info.plist NSBonjourServices):
  `_ceciliasnotes-sync._tcp`
- iPad **advertises** with `MCNearbyServiceAdvertiser`. discoveryInfo
  is `{"app": "ceciliasnotes", "platform": "ios"}`.
- Mac MCP **browses** with `MCNearbyServiceBrowser` for the same
  `serviceType`. Send `MCNearbyServiceBrowser.invitePeer(...)` to
  connect.

## Pairing

- First connection from a given peer name surfaces an alert on the
  iPad ("\<peer\> wants to send notebooks. Allow?").
- The peer name (`MCPeerID.displayName` — typically the Mac's
  hostname) is the trust key. Once accepted, the iPad remembers it
  in UserDefaults under `ceciliasnotes.multipeer.trustedPeers` and
  auto-accepts subsequent invitations from the same name.
- User can clear all trusted peers via Settings → cloud → "forget
  all paired devices".

## Payload format

A single binary blob sent via `MCSession.send(_:toPeers:with:.reliable)`.

```
+--------+------------------+---------------+
| 4 byte | UTF-8 JSON header | file body    |
| BE     | (header length)   | (rest of msg)|
+--------+------------------+---------------+
```

- **Bytes 0–3**: 32-bit big-endian unsigned int = length of the
  JSON header in bytes.
- **Bytes 4 … 4+headerLen-1**: JSON object, UTF-8.
- **Bytes 4+headerLen … end**: raw file bytes.

### Header schema

```json
{
  "filename": "Sketchbook.inkbook"
}
```

The iPad sanitises the filename: strips path separators, validates
the extension (`.inkbook` or `.json` only; other extensions are
rejected and replaced with a UUID `.inkbook`). Pick clean names on
the Mac side.

## After delivery

iPad writes the body to the iCloud inbox folder (same path
`CeciliasNotesFileWatcher` polls) and immediately calls
`rescan()` so the importer runs in milliseconds rather than waiting
for the next NSMetadataQuery DidUpdate.

iCloud will also propagate the same file via its usual mechanism;
the importer is idempotent on content hash so the duplicate is a
no-op.

## Status states the iPad reports

`MultipeerSyncService.status` is `@Published`. Settings displays:

- `.off` — toggle disabled
- `.idle` — advertising, no peers connected
- `.connected(peerName:)` — session up, awaiting payload
- `.receiving(peerName:)` — payload in flight
- `.received(peerName:, filename:)` — success
- `.error(String)` — transient failure (malformed payload,
  inbox unreachable, etc.)

## Error cases the sender should handle

- Invitation declined → `MCNearbyServiceBrowser` reports the
  decline; treat as "user said no, don't retry without user action".
- Connection timeout → MultipeerConnectivity is opaque about why.
  Re-discover after a short delay.
- iPad runs out of disk → iPad will report `.error(...)` but
  there's no in-band channel back to the Mac. Best-effort fall
  back to iCloud-only writes after a fixed number of failures.

## Example sender code (macOS, abridged)

```swift
import MultipeerConnectivity

let peerID = MCPeerID(displayName: Host.current().localizedName ?? "Mac")
let session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
let browser = MCNearbyServiceBrowser(peer: peerID, serviceType: "ceciliasnotes-sync")

browser.delegate = self  // implement foundPeer/lostPeer
browser.startBrowsingForPeers()

// In foundPeer:
browser.invitePeer(foundPeer, to: session, withContext: nil, timeout: 10)

// Once session.state == .connected:
let header: [String: Any] = ["filename": "Sketchbook.inkbook"]
let headerData = try JSONSerialization.data(withJSONObject: header)
var lenBE = UInt32(headerData.count).bigEndian
let lenBytes = Data(bytes: &lenBE, count: 4)

var payload = Data()
payload.append(lenBytes)
payload.append(headerData)
payload.append(fileBytes)

try session.send(payload, toPeers: [iPadPeer], with: .reliable)
```

---

## Versioning

- Header JSON is the extensibility point. Add new keys; the iPad
  only reads `filename`. Adding `notebookId` / `checksum` / etc.
  is forward-compatible.
- Bumping the framing format (the 4-byte length prefix) would
  break the iPad — if you ever need to, introduce a new
  `serviceType` (`ceciliasnotes-sync-v2`) and have the iPad
  advertise both for a transition window.

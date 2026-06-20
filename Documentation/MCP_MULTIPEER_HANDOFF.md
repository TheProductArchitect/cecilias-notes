# Hand-off Brief: Multipeer Sender for `cecilias-notes-mcp`

This is a self-contained brief for an LLM working in the
`cecilias-notes-mcp` repo (Node/TypeScript). It captures every
decision already made on the iPad side so you can implement the
Mac-side sender without re-litigating architecture.

---

## What's being built

A Mac-side sender that delivers `.inkbook` files directly to a
nearby iPad running Cecilia's Notes, sidesteppping iCloud's
30 sec – 5 min sync latency. The iPad side is already shipped
(branch `iphone-support`, commit `d1f2e90`). You're implementing
the Mac side.

End-state UX: user prompts an MCP-using agent to create a notebook,
notebook appears on the iPad in ~1 second when both devices are on
the same Wi-Fi or BT-PAN. Falls back to iCloud (existing behaviour)
otherwise.

---

## Architectural decisions (locked)

These were debated and resolved. Do not revisit unless you find a
concrete blocker.

### 1. Swift sidecar binary, not pure Node

MultipeerConnectivity is Apple-only. No Node binding exists.
Implement the multipeer logic as a Swift binary built via SwiftPM
(`cecilias-notes-multipeer`), shipped as a universal slice
(`arm64 + x86_64`) inside the npm tarball under
`node_modules/cecilias-notes-mcp/bin/`. Node MCP shells out to it
via stdio or a local Unix socket.

`npm install -g cecilias-notes-mcp` should make the sidecar
executable via an `npm postinstall` script.

### 2. Auto-try-first, 2-second timeout, silent fallback

`create_notebook` always writes to iCloud Inbox (existing path) —
that's the durable record. In parallel:

1. Probe for a paired iPad (multipeer discovery).
2. If a peer is found within ~500ms, send a `ping`.
3. If `pong` arrives within 500ms, send the file payload.
4. If anything stalls past 2 seconds total, abort and rely on the
   iCloud Inbox write.

The iCloud write is unconditional. Multipeer is a best-effort
accelerator on top. The iPad's importer is idempotent on content
hash, so the iCloud arrival becomes a no-op if multipeer beat it.

### 3. Tool result includes the chosen transport

`create_notebook` returns:

```json
{
  "notebook_id": "...",
  "delivery": {
    "transport": "multipeer" | "icloud",
    "peer": "Venu's iPad",                   // multipeer only
    "latency_ms": 847,                       // multipeer only
    "fallback_reason": "no_peer_visible"     // icloud-fallback only
                     | "ping_timeout"
                     | "session_failed"
                     | "user_not_paired",
    "estimated_latency_seconds": [30, 300]   // icloud-fallback only
  }
}
```

The agent can mention the fallback to the human ("notebook is on
the way via iCloud — give it a minute"). Never return a failure
tool result if the iCloud Inbox write succeeded.

### 4. Peer display name

`MCPeerID.displayName` on the Mac side = **`"cecilias-notes-mcp on <hostname>"`**

Examples:
- `cecilias-notes-mcp on Venu's MacBook Pro`
- `cecilias-notes-mcp on m4-mini`

Use `Host.current().localizedName` for `<hostname>`. The
`cecilias-notes-mcp on ` prefix is fixed so the iPad's
paired-devices list unambiguously identifies the sender as MCP,
not the human.

Hostname changes invalidate pairing — accepted cost. Re-pair takes
30 seconds on the iPad.

### 5. Pairing storage on Mac side

Mac's stored shared key goes in **macOS Keychain** (the system
keychain, NOT iCloud Keychain). Use the `Security.framework` API
with:

- `kSecClass = kSecClassGenericPassword`
- `kSecAttrService = "app.ceciliasnotes.multipeer.sharedKey"`
- `kSecAttrAccount = <iPad's MCPeerID.displayName>`
- `kSecAttrSynchronizable = false`
- `kSecAttrAccessible = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`

This mirrors the iPad side exactly so the pairing model is symmetric.

---

## Wire protocol

The complete spec is at `Documentation/MULTIPEER_SYNC_PROTOCOL.md`
in the Cecilia's Notes repo. Read it end-to-end before coding.

The five message types you'll send / receive:

| Type | Direction | Body | When |
|---|---|---|---|
| `pairing-hello` | Mac → iPad | empty | First-time pairing |
| `ping` | Mac → iPad | empty | After session connect, before file |
| `pong` | iPad → Mac | empty | iPad's reply to `ping` |
| `file` | Mac → iPad | raw `.inkbook` bytes | The actual delivery |
| (none) | iPad → Mac | n/a | iPad never sends `file` |

Every payload: `[4 byte BE length][header JSON][32 byte HMAC][body]`.

HMAC-SHA256 over `headerJSON || body`. Key:
- `pairing-hello`: derived from the user-typed 6-digit code via
  HKDF (see spec for exact inputs).
- `ping`, `file`: the stored shared key for the iPad's
  displayName.

---

## Discovery details

- Service type: `ceciliasnotes-sync` (without underscores or `._tcp`
  suffix — that's just how MC presents it; on the wire it becomes
  `_ceciliasnotes-sync._tcp`).
- Bonjour record on macOS works out of the box; no entitlement
  needed for browsing as a CLI tool.
- iPad advertises `discoveryInfo = { app, platform, v }`. You can
  ignore this — just invite any peer that matches the service type.

---

## Implementation outline (Swift sidecar)

```
cecilias-notes-multipeer/
├── Package.swift
├── Sources/
│   └── CeciliasNotesMultipeer/
│       ├── main.swift               // CLI entry
│       ├── PeerBrowser.swift        // MCNearbyServiceBrowser
│       ├── PairingSession.swift     // pairing-hello + HKDF + Keychain
│       ├── SendSession.swift        // ping → file flow
│       ├── PayloadBuilder.swift     // length-prefix + HMAC framing
│       └── Keychain.swift           // SecItem* wrapper
```

Commands the Node MCP invokes:

```
cecilias-notes-multipeer send \
  --peer "Venu's iPad" \
  --file ./payload.inkbook \
  --filename "Sketchbook.inkbook" \
  --timeout-ms 2000

# stdout (one JSON line):
{"ok": true, "latency_ms": 847, "peer": "Venu's iPad"}
# or:
{"ok": false, "reason": "ping_timeout"}
```

```
cecilias-notes-multipeer pair \
  --peer "Venu's iPad" \
  --code "418294"

# stdout:
{"ok": true, "paired": "Venu's iPad"}
# or:
{"ok": false, "reason": "wrong_code" | "pairing_window_expired"}
```

```
cecilias-notes-multipeer list-paired

# stdout:
{"peers": ["Venu's iPad", "Venu's Other iPad"]}
```

```
cecilias-notes-multipeer forget --peer "Venu's iPad"

# stdout:
{"ok": true}
```

```
cecilias-notes-multipeer discover --timeout-ms 1500

# stdout (newline-delimited JSON, one per peer):
{"peer": "Venu's iPad", "paired": true}
{"peer": "Other iPad", "paired": false}
```

Keep the CLI surface narrow. The Node MCP composes these into the
`create_notebook` flow:

```typescript
async function deliverNotebook(file: Buffer, filename: string) {
  // 1. Write to iCloud Inbox unconditionally
  const icloudWrite = writeToIcloudInbox(file, filename);

  // 2. Try multipeer in parallel
  const multipeerSend = (async () => {
    const peers = await runCli("discover", { "timeout-ms": 1500 });
    const paired = peers.filter(p => p.paired);
    if (paired.length === 0) {
      return { ok: false, reason: "no_peer_visible" };
    }
    return runCli("send", {
      peer: paired[0].peer,
      file: tempPath(file),
      filename,
      "timeout-ms": 2000,
    });
  })();

  // 3. Race; iCloud write is always awaited
  const [icloudResult, multipeerResult] = await Promise.all([
    icloudWrite,
    multipeerSend,
  ]);

  return {
    delivery: multipeerResult.ok
      ? { transport: "multipeer", peer: multipeerResult.peer, latency_ms: multipeerResult.latency_ms }
      : { transport: "icloud", fallback_reason: multipeerResult.reason, estimated_latency_seconds: [30, 300] }
  };
}
```

---

## Pairing UX from the human's perspective

First time the user wires up the Mac MCP after the new sender ships:

1. User runs an MCP command that hits `deliverNotebook`. Multipeer
   tries, fails with `reason: "user_not_paired"`. Agent surfaces:
   *"Want me to pair this Mac to your iPad? Open Settings → cloud
   on the iPad, tap 'show pairing code', and tell me the
   6 digits."*
2. User does it. The MCP-using agent calls
   `cecilias-notes-multipeer pair --peer "..." --code "418294"`.
3. Sidecar runs the HKDF + pairing-hello flow. On success, stores
   the key in Keychain and reports back.
4. Subsequent `create_notebook` calls auto-use multipeer.

Alternatively the user can pair without an agent by running the
CLI directly. Document both flows in the MCP README.

---

## Test plan (Mac side)

1. **Pairing happy path**: pair against a real iPad, verify
   subsequent sends succeed within 2s.
2. **Pairing wrong code**: enter a wrong 6-digit code, verify
   `{ ok: false, reason: "wrong_code" }`.
3. **Pairing window expired**: wait 91 seconds after the iPad
   showed the code; pair attempt should fail with
   `pairing_window_expired`.
4. **No iPad visible**: turn off the iPad's multipeer toggle;
   send should fall back with `no_peer_visible` within 1.5s.
5. **Ping timeout**: kill the iPad app mid-session; second send
   should fall back with `ping_timeout` within ~500ms.
6. **Clock skew**: set the Mac's clock 90s into the future;
   pairing should fail with a stale-timestamp reason. (Spec says
   the iPad will report "stale payload"; in the CLI output
   surface it as `clock_skew`.)
7. **HMAC mismatch**: corrupt the stored key in macOS Keychain;
   send should fail with `hmac_rejected`.
8. **Replay**: send the same payload twice (same nonce); second
   should be rejected. The CLI should never re-use a nonce, so
   this is purely a defensive test.

---

## Out of scope for v1

- Receiving files from iPad → Mac. iPad never sends `file`. Don't
  build a receive path.
- Multi-peer broadcast (one send → many iPads). Pick the
  best-match paired peer. If the user has multiple paired iPads,
  add a `--peer` selector flag and document it; default to the
  most-recently-paired peer.
- Background sending. The sidecar process runs only for the
  duration of a single command invocation. No long-lived daemon.
- Stable-installation-ID-keyed pairing (so Mac hostname renames
  don't invalidate trust). Defer until someone complains.

---

## Files in this repo you should read

1. `Documentation/MULTIPEER_SYNC_PROTOCOL.md` — the wire spec.
2. `CeciliasNotes/CeciliasNotes/Core/Services/MultipeerSyncService.swift`
   — the iPad-side receiver. The Swift sidecar's send + pair
   flows mirror this implementation closely; reading it is the
   fastest way to internalise the design.
3. `CeciliasNotes/CeciliasNotes/Core/Services/MultipeerPairingStore.swift`
   — Keychain + HKDF wrapper. The macOS equivalent should use
   identical inputs to land on identical keys.

---

## When to ping back

Open a GitHub issue / pull-request on Cecilia's Notes if you find:

- An ambiguity in the wire protocol (anything not covered
  above where you'd have to guess).
- A failure mode the iPad doesn't handle gracefully.
- An iPad-side bug surfaced by the real Mac sender.

Otherwise, ship the Mac side independently and post an
announcement when it's installable. The iPad side won't change
unless the spec rev's.

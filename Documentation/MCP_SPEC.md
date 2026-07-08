# MCP Integration — Source of Truth (PRD)

**Status: living document.** This is the authoritative spec for how
external agents (the `cecilias-notes-mcp` server and any future MCP
tooling) read from and write into Cecilia's Notes. Any change to the
importer, exporter, `.inkbook` schema, or transport MUST update this
doc in the same commit. The change log at the bottom is the audit
trail.

Related docs (narrower scope, subordinate to this one):
- `MULTIPEER_SYNC_PROTOCOL.md` — wire format for the LAN fast path.
- `MCP_MULTIPEER_HANDOFF.md` — implementation brief for the Mac-side
  sender (historical; decisions captured there are restated here
  where they affect the iPad contract).

---

## 1. Product intent

An AI agent on a Mac (or anywhere that can reach the user's iCloud
Drive) can:

1. **Create** notebooks with structured typed content.
2. **Read** every notebook — including user-typed text, dictated
   text, and whether pages carry Pencil ink.
3. **Append / edit** without clobbering concurrent iPad-side edits.

The user experience target: prompt an agent → notebook appears on the
iPad in ~1 s on the same LAN (multipeer), ≤5 min otherwise (iCloud).
AI-written notebooks must look clean and intentional — **white
(blank) pages, well-margined typography** — never like they're
fighting a ruled template.

## 2. Data flow

```
                 write .inkbook                     read mirror
  Agent/MCP ───────────────────────►  iCloud Inbox ◄─────────── Agent/MCP
      │                                    │  ▲
      │  multipeer fast path (LAN)         ▼  │ mirror written on:
      └────────► MultipeerSyncService → CeciliasNotesFileWatcher   • import
                 (HMAC, paired)            │                       • app launch
                                           ▼                       • backgrounding
                               CeciliasNotesImporter               • notebook edit
                                           │
                                           ▼
                              SwiftData (Notebook/Page/TextBlock)
                                           │
                                           ▼
                               CeciliasNotesExporter  ──► mirror .inkbook
```

- **Inbox** (agent → iPad): iCloud Drive folder watched by
  `CeciliasNotesFileWatcher`; also fed by `ShareInboxWatcher` (share
  extension) and `MultipeerSyncService` (LAN push).
- **Mirror** (iPad → agent): one `.inkbook` per live notebook,
  re-exported by `CeciliasNotesExporter` so the agent's read view is
  current.

## 3. The `.inkbook` schema (v1.1)

Codable contract: `Core/Models/CeciliasNotesFile.swift`. JSON,
snake_case, top-level fields:

| Field | Type | Notes |
|---|---|---|
| `$schema` | string? | informational |
| `version` | string | schema version |
| `id` | string (UUID) | notebook identity — imports dedupe on this |
| `title`, `subject` | string | subject is matched case-insensitively, created if missing; empty subject → `"MCP"` |
| `created_at`, `updated_at` | ISO-8601 string | exporter uses default `ISO8601DateFormatter` (seconds, UTC) |
| `cover_tone` | string? | `parchment · studio-white · ash · coal · midnight · moss · dusk · ink-black` |
| `page_template` | string? | `blank · lined · grid · dot-grid · cornell · music` — **ignored for agent-authored files** (§5) |
| `page_size` | string? | `a4 · letter · ipad-canvas` (default a4) |
| `agent` | object? | `{written_by, model?, tool, tool_version}` — presence marks the file agent-authored; round-trips verbatim |
| `mcp_action` | string? | `create · append · replace` (§4) |
| `base_updated_at` | string? | optimistic-concurrency base (§4) |
| `pages` | array | ordered by `index` |

Page node: `{id, index, created_at?, blocks[], has_ink?}` —
`has_ink` is emitted by the mirror so agents can distinguish "user
wrote with the Pencil" from "empty page". Agents never write it.

Block union (unknown `type`s are skipped, never fail the file):

```
heading(content, level 1–3) · paragraph(content)
list(style: bullet|numbered, items[]) · code(content, language?)
divider · quote(content, attribution?) · callout(content, kind: note|warning|tip)
```

## 4. Write semantics — concurrency contract

Resolved in `CeciliasNotesImporter.pageWriteStrategy` (unit-tested):

| `mcp_action` | Notebook exists? | Result |
|---|---|---|
| any / none | no | create fresh |
| `create` | yes | **replace** (MCP view authoritative on id collision) |
| `replace` | yes | **replace** (explicit overwrite) |
| `append` | yes, `base_updated_at` == live `updatedAt` | replace (no concurrent edit happened) |
| `append` | yes, base mismatch/missing | **merge**: keep all live pages, add only incoming pages whose id is new |
| none (old MCPs, hand-dropped files) | yes | **merge** — the safe default; a stale writer must not clobber iPad work |

Invariants:
- Import is **idempotent** by notebook UUID.
- Imports are **serialized FIFO in arrival order** (added 2026-07-03)
  — two rapid writes can't persist out of order even if the older
  file parses slower.
- A `replace` deletes `Page`/`TextBlock` rows but **not** V6
  `PageElement`s keyed by pageId — user ink survives a replace when
  the agent keeps page ids stable. (Corollary: agents SHOULD reuse
  page ids when rewriting a page's text.)

## 5. Rendering rules for agent content

- **Template: agent-authored files always land on `.blank` (white
  page)**, regardless of `page_template`. Typed text never aligns
  with rule spacing, so ruled/dot backgrounds make AI pages look
  broken. The agent's requested template is still stored and
  round-tripped in the mirror unmutated. Non-agent `.inkbook` files
  (no `agent` block) honour the requested template. Default when the
  field is absent: `blank`.
- **Layout:** each page's blocks render into one full-width rich-text
  block at `x=0.10, y=0.06, width=0.80, height=0.88` (10% side
  gutters, matching the editor's own text margin).
- Source blocks are stashed verbatim on `Page.inkbookBlocksJSON` so
  the mirror re-emits them byte-identically (no lossy round-trip).

## 6. Read (mirror) guarantees

The exporter emits, per page:
1. Stashed agent blocks (verbatim) when present.
2. Legacy `TextBlock` text.
3. V6 `PageElement(.text)` content — user-typed AND dictated text.
4. `has_ink` flag from the stroke element.

Mirror refresh points: every import, app launch (`exportAll`),
app backgrounding, and notebook mutation paths. Agent metadata
(`written_by/model/tool/tool_version`) round-trips exactly.

## 7. Transports

1. **iCloud Inbox** (durable, unconditional) — the record of truth;
   30 s–5 min latency.
2. **Multipeer LAN push** (best-effort accelerator, ~1 s) — HMAC
   pairing per `MULTIPEER_SYNC_PROTOCOL.md`; received files are
   written into the same Inbox and go through the same importer, so
   the iCloud copy arriving later is an idempotent no-op.
3. **Share extension inbox** — same importer.

All three converge on `CeciliasNotesImporter`; the FIFO ordering
guarantee (§4) covers cross-transport races.

## 8. Known limitations / future work

- **AI text is legacy-layer**: imported text becomes `TextBlock`
  (V5), not `PageElement(.text)` (V6). It renders and exports fine
  but is invisible to the lasso/element system (can't be
  lasso-selected/moved) until the pending TextBlock→PageElement
  migration step. When that migration lands, §5 layout rules apply
  to the V6 rows and this doc must be updated.
- **Orphaned V6 elements**: a `replace` with *changed* page ids
  leaves old pages' `PageElement` rows unreachable (no cascade).
  Harmless today; a reaper sweep is a candidate follow-up.
- Only text-family blocks exist; images/audio in the schema are
  future work.

## 9. Checklist for future changes (keep this doc honest)

When touching any of: `CeciliasNotesFile`, `CeciliasNotesParser`,
`CeciliasNotesImporter`, `CeciliasNotesExporter`,
`CeciliasNotesFileWatcher`, `MultipeerSyncService`:

- [ ] Does the `.inkbook` field table (§3) still match the Codable?
- [ ] Did write semantics (§4) change? Update the matrix + unit tests.
- [ ] Did rendering defaults (§5) change? Blank-template rule is a
      product decision — do not regress it silently.
- [ ] Schema changes must be **additive + optional** (old app builds
      must still parse new files; unknown blocks skip, unknown
      `mcp_action` falls back to merge).
- [ ] Append an entry to the change log below.

## Change log

| Date | Change |
|---|---|
| 2026-07-03 | Doc created. Import pipeline serialized FIFO (out-of-order clobber fix). Documented blank-template rule, merge-by-default strategy, mirror guarantees, V6 text-layer limitation. |
| 2026-07-07 | Hardening: parser rejects `.inkbook` files over 32 MB (`CeciliasNotesParser.maxFileBytes`) before reading them into memory; the same cap applies to multipeer file payloads and quiz MCP responses. Multipeer pairing window now closes after 5 wrong-code hellos (brute-force guard). No schema or write-semantics changes. |
| 2026-07-07 | In-app "Send to Device": any platform can ship a notebook's `.inkbook` over the paired multipeer link (`MultipeerNotebookShare` → `"file"` payload → receiver Inbox → same importer, merge-by-default). Offered only for cross-Apple-Account peers — same-account devices sync via CloudKit and importing a mirror alongside it would duplicate the text layers. Pairing messages now exchange `householdHash` (additive) so both sides know which case they're in. MCP server 2.1.0 enforces the 32 MB cap at write time with an actionable error. |
| 2026-07-08 | MCP server 2.2.0: `pair_ipad` auto-pairs with no code when the Mac shares the iPad's Apple Account (sidecar reads the iCloud-Keychain household key, derives the first-party HKDF key, same pairing-hello flow; one-time macOS Keychain consent prompt). Also fixes the sidecar's HKDF info string to sort peer names like the receiver always has — manual pairing previously only worked when the Mac's peer name sorted first. |

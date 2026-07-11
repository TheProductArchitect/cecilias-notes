# Project State

_Kept short and current. Any LLM opening this repo should read this file first, then [`CODE_GRAPH.md`](CODE_GRAPH.md) for a structural map._

Last updated: 2026-07-10

## Elevator pitch

Cecilia's Notes is a Zara-editorial handwriting-first note-taking app. Two Xcode targets share one SwiftUI codebase over a SwiftData + CloudKit store, with MultipeerConnectivity for local peer sync:

- `CeciliasNotes` — iPad + iPhone (primary; handwriting on iPad only)
- `CeciliasNotesMac` — Mac companion (read strokes, edit typed content + media)

Universal Purchase, shared bundle id `app.ceciliasnotes`, shared CloudKit container `iCloud.app.ceciliasnotes`, shared App Group `group.app.ceciliasnotes`.

## Current phase

**Production push: cross-device sync UX + Mac meeting assistant (2026-07-07).**

1. **Same-Apple-Account devices on one LAN feel live.** Every platform now
   runs both multipeer lanes (advertise + browse — previously only the Mac
   browsed), auto-pairs via the iCloud-Keychain household key, and receive
   defaults ON. Notebook mutations broadcast `notebook-changed` hints; the
   receiver refreshes the library, refreshes the open editor (guarded on
   `isDirty`), and nudges `CloudSyncManager.syncNow()` for media. Content
   truth stays CloudKit — the hint layer removes the "why isn't it here
   yet" dead air. Do NOT ship notebook content over multipeer between
   same-account devices: importing a mirror alongside CloudKit duplicates
   the V5/V6 text layers.
2. **Cross-Apple-Account share ("Send to Device").** Paired-but-different-
   account peers get a context-menu send (`MultipeerNotebookShare` →
   `"file"` payload → receiver Inbox → importer, merge-by-default).
   Pairing messages exchange `householdHash` so Settings can explain which
   case the user is in. Protocol v2.3 (see `MULTIPEER_SYNC_PROTOCOL.md`).
3. **Meeting assistant (Mac + iPad).** "Meeting Transcription" streams
   words into the page; on stop, `TranscriptStructurer` restructures the
   transcript in place (paragraphs, headings, speaker labels — words
   verbatim, single-block sessions only), then `MeetingSummarizer`
   distills it with on-device Apple Intelligence (chunked map-reduce).
   Placement differs by canvas: the Mac inserts a "SUMMARY" block ABOVE
   the transcript (doc-mode reflow handles geometry); the iPad PREPENDS
   the summary INTO the transcript element (`MeetingSummaryCommit`) — a
   separate element had to guess free-canvas geometry and overlapped ink.
   All failures degrade to transcript-only, never an error state on the
   page.
4. **Dictation continues sentences.** Utterance boundaries from
   `SFSpeechRecognizer` are noisy, so the fallback separator is a space —
   the sentence continues; a new paragraph opens only after a real pause
   (≥2.5 s, `LectureRecorder.paragraphPauseSeconds`).

**Verified end-to-end 2026-07-08:** both app targets build, full unit
suite green on the iOS 26.4 iPad simulator, MCP server tests pass, Swift
sidecar builds, and the dictation → structure → summary → multipeer-hint
chain plus the cross-account share path were re-traced call-site by
call-site.

Previous phase — **Mac editor parity + accessibility pass.** Both targets build green. Recent Mac editor work:

1. **Rich text** — `MacRichTextEditor` + `MacRichTextFormatBar` read/write `TextContent.attributedTextData` (same keyed archive as iPad).
2. **Element transform** — `MacElementTransform` drag + corner-resize for selected text, image, sticky, shape elements.
3. **Sticky notes** — insert via toolbar/menu; double-tap to edit in `MacStickyNoteEditorSheet`.
4. **Image insert** — `NSOpenPanel` + `MacImportService` from toolbar, menu, and drag-drop.
5. **Export share** — `MacExportSheet` offers **Share…** via `NSSharingServicePicker` after save.
6. **Accessibility** — element labels on `MacElementView`, page-strip thumbnails, audio play/pause labels; focus mode (⌃⌘F), minimap when zoomed.

Still partial on Mac (p2 / platform limits): image crop on iPad, per-page custom paper hex, Files provider, full Tab-through-chrome loop, widgets deep link polish.

## Production checklist — Mac (2026-07-06)

- **Icons** — `CeciliasNotesMac/Resources/Assets.xcassets` (16–512 @1x/@2x) generated from iPad `AppIcon-1024.png`
- **Build** — `CURRENT_PROJECT_VERSION = 2` aligned with iOS; Universal Purchase bundle `app.ceciliasnotes`
- **Entitlements** — iCloud, App Group, hardened runtime, local network + Bonjour for Multipeer
- **Privacy strings** — microphone, speech, local network in `Info.plist`
- **App Store copy** — see `APP_STORE_COPY.md` Mac subtitle + description block
- **Human smoke test** — drag PDF onto library, open notebook, edit text/image, export + share, handoff from iPad

## Repo shape (source of truth in [`CODE_GRAPH.md`](CODE_GRAPH.md))

```
CeciliasNotes/                     Xcode project root
├── CeciliasNotes/                 iOS + iPadOS target (also compiled for Mac target via synced folders)
│   ├── App/                       @main, RootView, environment wiring
│   ├── Core/
│   │   ├── Capabilities/          DeviceCapabilities, feature gates
│   │   ├── Models/                SwiftData models (V6 is current schema)
│   │   ├── Services/              StorageService, CloudSyncManager,
│   │   │                          MultipeerSyncService, SearchIndexService,
│   │   │                          IntelligenceService, AI providers, MediaStorage
│   │   ├── Extensions/            Foundation/SwiftUI extensions
│   │   └── Utilities/             PlatformKit (typealiases), ImageIO helpers
│   ├── DesignSystem/              Theme, Colors, Typography, BrandWordmark, animations
│   ├── Features/
│   │   ├── Library/               LibraryView, sidebar, grid, search, ask
│   │   ├── Editor/                canvas, strokes, tools, lecture, lasso, PDF elements
│   │   ├── Onboarding/            PersonalIdentity, iPad OnboardingView
│   │   ├── Quiz/                  quiz builder + player
│   │   ├── Settings/              iOS settings sections
│   │   └── Sync/                  status indicator, banners
│   └── Resources/                 Info.plist, Assets, entitlements, SVGs, Greetings.swift
└── CeciliasNotesMac/              Mac target — hosts the SwiftUI scene, reuses iPad views
    ├── CeciliasNotesMacApp.swift  @main + MultipeerSyncService.shared kick
    ├── MacRootView.swift          full-plane masthead + sidebar + content composition
    ├── MacToolbar.swift           toolbar + CommandGroup for ⌘N/⌘E/⌘T/⌘,
    ├── App/MacAppDelegate.swift   handoff + settings observer
    ├── Editor/MacEditorView.swift Mac page editor (strokes read-only; typed + media editing)
    ├── Editor/MacRichTextEditor.swift   NSTextView rich text + format bar
    ├── Editor/MacElementTransform.swift drag/resize handles for page elements
    ├── Editor/MacMinimapView.swift      scroll minimap when zoomed
    ├── Editor/MacEditing.swift          insert/edit helpers + sheets
    ├── Editor/MacRendering.swift        element views + accessibility labels
    ├── Onboarding/                MacOnboardingView (name → sync → done)
    ├── Settings/                  MacSettingsView (⌘, target)
    ├── Export/                    Mac export sheet
    ├── Library/                   MacEmptyState, MacLibraryState, MacElementEditing
    ├── Search/                    Mac search UI
    └── Services/                  MacHandoff, MacImportService
```

Documentation index:

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — deep dive on the iPad architecture (models, sync, editor pipeline)
- [`MAC_APP_PRD.md`](MAC_APP_PRD.md) — Mac companion PRD (design, UX, rollout M0–M6)
- [`USER_FLOWS.md`](USER_FLOWS.md) — every user flow, per device, with status and UX notes (iPad = source of truth, Mac benchmarks Granola)
- [`USER_FLOWS.yaml`](USER_FLOWS.yaml) — machine-queryable version of the flows for LLM tooling
- [`prompts/verify_user_flows.md`](prompts/verify_user_flows.md) — cold-start prompt: verify every flow, fix gaps, report
- [`CODE_GRAPH.md`](CODE_GRAPH.md) — machine-scanned map of files/types/notifications
- [`MULTIPEER_SYNC_PROTOCOL.md`](MULTIPEER_SYNC_PROTOCOL.md) — local peer sync wire format
- [`OPEN_ISSUES.md`](OPEN_ISSUES.md) — known bugs / punchlist
- [`PRODUCTION_READINESS.md`](PRODUCTION_READINESS.md) — TestFlight/App Store gate items
- [`MEDIA_SUBSYSTEM_AUDIT.md`](MEDIA_SUBSYSTEM_AUDIT.md) — audio/image/PDF pipeline audit

## Runtime wire diagram (concise)

```
                ┌────────────────────────┐
                │ CeciliasNotesApp @main │ ── environment injects ▶ StorageService, CloudSyncManager, ThemeManager, HapticManager
                └───────────┬────────────┘
                            │
                     RootView / MacRootView
                            │
             ┌──────────────┼──────────────┐
             ▼              ▼              ▼
       LibraryView     EditorView     Settings*View
             │              │
             │              └── PageElement (SwiftData) ── strokes / typed / PDF / media
             │                        ▲
             │                        │
             ▼                        │
   LibraryViewModel ── SwiftData ─────┘
             │
             └── SearchIndexService (in-memory + Spotlight)

  Persistence: SwiftData (CoreData under the hood) → CloudKit private db
  Local sync : MultipeerSyncService (Bonjour _cn-sync._tcp)
  App Group  : group.app.ceciliasnotes — widgets + name mirroring
  Message bus: NotificationCenter — see CODE_GRAPH.md § Notification bus
```

## Where things live (LLM cheat sheet)

| I want to … | Look at |
| --- | --- |
| Change what a notebook cover renders like | `Features/Library/Grid/NotebookGridView.swift`, `CoverTextureCanvas.swift`, `Core/Models/V6/NotebookCoverTone.swift` |
| Add a stroke tool | `Features/Editor/Tools/*` and `CeciliasNotesTool.swift` |
| Touch the sync banner | `Features/Sync/SyncStatusIndicator.swift` (iOS), `CeciliasNotesMac/MacRootView.swift` `MacSyncBanner` (Mac) |
| Change personalisation copy or wordmark | `DesignSystem/BrandWordmark.swift`, `Features/Onboarding/PersonalIdentity.swift`, `Resources/Greetings.swift` |
| Adjust CloudKit behaviour | `Core/Services/CloudSyncManager.swift`, `Core/Services/CloudKitContainerState.swift` |
| Adjust multipeer sync | `Core/Services/MultipeerSyncService.swift`, `Core/Services/MultipeerPairingStore.swift` |
| Add a new SwiftData model | `Core/Models/V6/*` (bump migration if breaking) |
| Wire a new Mac command | `CeciliasNotesMac/MacToolbar.swift` `MacAppCommands` |
| Mac rich text / element editing | `CeciliasNotesMac/Editor/MacRichTextEditor.swift`, `MacElementTransform.swift`, `MacEditing.swift` |
| Debug a NotificationCenter miss | `CODE_GRAPH.md § Notification bus` — post/observe callsites are enumerated |
| Understand cross-target exceptions | Search `CeciliasNotes.xcodeproj/project.pbxproj` for `PBXFileSystemSynchronizedBuildFileExceptionSet` |

## Debug playbook

**When something breaks on Mac only:**
1. Confirm the file compiles for the Mac target — check `project.pbxproj` for a `membershipExceptions` entry excluding it.
2. Grep the file for `#if canImport(UIKit)` / `#if os(iOS)` — the else branch (or missing branch) is the Mac codepath.
3. Confirm `PlatformImage` / `PlatformColor` shims from `Core/Utilities/PlatformKit.swift` are used instead of `UIImage`/`UIColor`.

**When the app hangs (ANR) — main-thread rules (2026-07-09):**
- Keystroke persist in `TextElementView` is debounced (350 ms) with the `NSKeyedArchiver` encode off-main, and layout re-measure throttled to 250 ms. Never reintroduce per-keystroke encode/measure — an hour-long transcript block made every keystroke cost hundreds of ms.
- Dictation partials mutate `content.text` per partial (drives the live UI) but `context.save()` at most once per second (`DictationFlowCommit.throttledDictationSave`), with a trailing pass. Stop-time commits save unconditionally.
- The `.inkbook` mirror export builds on a background `ModelContext` (`CeciliasNotesExporter.exportInBackground`) — pass IDs across the isolation boundary, never model objects. `scheduleExportAll` runs at launch/backgrounding/termination, all watchdog-sensitive; building on main there ate the ~5 s background budget (0x8badf00d).
- `reconcileSoftDeleteFlags` fetches ONLY mismatched rows via predicates; the healthy case materializes nothing. Don't add full-table fetches to anything scheduled by `NSPersistentStoreRemoteChange` — it fires 2 s after every local save burst.
- Stroke persistence (2026-07-10): `PKDrawing.dataRepresentation()` is 50–300 ms for an inked page — NEVER call it on main in a scroll/draw path. `EditorViewModel.savePageAsync` (cache write-through → detached encode → main row write) serves the drawing-debounce, warm-band unmounts, and deferred unmount flushes; the synchronous `savePage` is reserved for teardown/dismiss durability. Canvas mounts fetch the stroke blob on a background `ModelContext` too (`ContinuousCanvasView` mount path) — reading a multi-MB blob on main per mount was the scroll hitch.
- Dictation partials: `TextElementView` coalesces external-text reseeds to 250 ms trailing — every reseed relayouts the whole UITextView, and doing it per partial saturated main for the length of a recording.
- Multipeer sends (2026-07-10): every outbound `MCSession.send` goes through `MultipeerSendQueue` (background serial queue in `MultipeerNotebookHint.swift`) — NEVER call `session.send` on main. A `.reliable` send blocks for seconds when the DTLS link is dying ("sendmsg error: No route to host" spam) while the peer is still listed in `connectedPeers` (a peer that left the LAN takes tens of seconds to drop out). Stroke saves broadcast notebook-changed hints every ~1.2 s while drawing — on a zombie link each hint wedged main ("froze after a few strokes" device report). Hints are additionally coalesced to one leading + one trailing send per 3 s per notebook, and `MultipeerPairingStore.sharedKey` is memory-cached (the raw lookup is a blocking `SecItemCopyMatching` XPC to securityd, previously paid per peer per hint).
- Page-host reconcile (2026-07-10, device-log confirmed): `ContinuousCanvasView` diffs the page list and reuses hosts for surviving pages (`reconcilePageHosts`) — never reintroduce "rebuild from scratch on any list change." A page row flapping in/out of the fetch (issue #3's un-deleter) turned the full rebuild into a loop: 9 UIKit hosts + overlay trees + PKCanvasViews torn down and rebuilt repeatedly on main, freezing the app at tool=cursor before drawing even started. `fetchPages` sorts with tie-breakers (pageNumber, createdAt, id) so duplicate page numbers can't flap the order either.
- Thumbnail cache keys (2026-07-10, device-log confirmed): `PageThumbnailCache.composeKey` must stay a pure property read — the key is `(pageId, page.updatedAt, pdfFingerprint)`. Keying on a fingerprint of the stroke BYTES meant two full main-actor blob reads per inked page per save tick (plus one per strip row at editor open via `StrokeCache` prewarm) — the confirmed "froze after a few strokes" ANR (continuous `sqlite3_step` faults in the device console). Corollary: any stroke rewrite that bypasses `updatePageStrokes` must call `StrokeCommit.stampPage` so thumbnails re-key.
- Post-stroke OCR (2026-07-10): `SearchIndexService.runOCR` reads the drawing cache-first (warm right after drawing via `savePageAsync` write-through); on a miss the blob fetch AND `PKDrawing` decode run on a background `ModelContext`. Never pull a stroke blob out of SQLite on the main actor in anything scheduled after a stroke burst.
- `CeciliasNotesPKCanvasView.editingInteractionConfiguration == .none` is load-bearing: iPadOS's system three-finger swipe fires `undoManager.undo()`, PencilKit registers every stroke there, and multi-finger scrolling across an inked canvas read as that swipe — strokes "undid themselves." Do not remove; toolbar/squeeze-wheel undo call `undoManager` directly and are unaffected.

**When SwiftData behaves oddly:**
- `StorageService.purgeDuplicateRows()` and `reconcileSoftDeleteFlags()` run on init and library appear — recent duplicate-ID crash was fixed by making every SwiftData-fed `ForEach` tolerate duplicates (see commit `d629830`).
- Duplicate-tolerant lists that feed the *editor* must keep the NEWEST row (`dedupedByIdNewestWins()` in `Array+DedupedById.swift`) — first-wins dedupe surfaced stale duplicate pages and read as phantom "undo".
- `reconcileSoftDeleteFlags()` fixes each row at most once per session. `NSPersistentStoreRemoteChange` fires for LOCAL saves too, so a sweep that saves and reschedules unconditionally loops forever. If a row reverts after its one fix, the sweep logs `REVERTED after an earlier fix this session` — that log line names the row to root-cause, it is not the bug itself.

**When a notification doesn't fire:**
- The bus is stringly-typed. Check `CODE_GRAPH.md § Notification bus` — every declared `Notification.Name` is listed with its posters and observers. Zero observers usually means a rename drifted.

**When personalisation doesn't stick:**
- Three keys: `PersonalIdentity.nameKey` (`app.user.name`), `PersonalIdentity.onboardingCompletedKey` (`app.onboarding.completed`), and the App Group mirror written via `mirrorNameToAppGroup`. The widget reads only the App Group copy.

**When iCloud is silent:**
- `CloudKitContainerState.status` drives every banner. The failure modes are `.localOnlyFallback` (not signed in) and `.uninitialized` (first-run indexing). Everything else stays silent — that's intentional.

**When multipeer won't advertise:**
- Mac target needs `com.apple.security.network.client` + `.network.server` entitlements _and_ `NSBonjourServices` (`_cn-sync._tcp`, `_cn-sync._udp`) + `NSLocalNetworkUsageDescription` in Info.plist.

## Regenerating the code graph

After any structural change (new module, new notification symbol, new service):

```bash
python3 Documentation/tools/build_code_graph.py
```

This rewrites `Documentation/CODE_GRAPH.md` and `Documentation/CODE_GRAPH.json`. The script is lexical (regex over Swift source) — cheap, deterministic, no toolchain. Not a full CPG in the Joern sense; it captures files, types, imports, protocol conformance, and the `NotificationCenter` bus. That's enough to orient any LLM.

## Non-obvious constraints

- **Handwriting is iPad-only, forever.** Mac reads strokes, doesn't author them. Do not add PencilKit UI to the Mac target.
- **Swift 6 strict concurrency is on.** `UIImage` is `@MainActor` — image encoding goes through `PlatformImageFactory` in `PlatformKit.swift` (ImageIO-backed) to avoid main-actor inference.
- **Bundle ID `app.ceciliasnotes` is shared** between iOS and Mac targets for Universal Purchase — do not change it, and do not add per-target suffixes.
- **The Zara editorial language is load-bearing.** 8pt tracked uppercase eyebrows, 11pt italic serif rows, SF Heavy wordmark, 96pt GhostLetter, 2pt selection rule. Chrome should be quiet — never a permanent floating warning strip.
- **`UIColor(dynamicProvider:)` / `NSColor(name:dynamicProvider:)` closures MUST be `@Sendable` over pre-resolved colors.** UIKit resolves dynamic colors on whatever thread asks — including SwiftUI's `AsyncRenderer` render thread, WHILE HOLDING SwiftUI's render-graph lock. An unannotated provider closure inherits @MainActor under default isolation → runtime isolation assert → SIGTRAP on the render thread with the lock held. Attached to Xcode the trap suspends the process in lldb and main deadlocks on that lock inside `touchesBegan` — the app reads as a total silent freeze (no logs, watchdog suspended); detached it's an instant crash. Confirmed by device `.ips` 2026-07-11 (`Color.init(light:dark:)` in `CeciliasNotesColors.swift`, thread `com.apple.SwiftUI.AsyncRenderer`; main blocked in `EventBindingBridge.send → _MovableLockLock`).
- **Never form a closure for a background-invoking framework API in a MainActor context under a `@preconcurrency` import.** The app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; `@preconcurrency import` silences the compile-time isolation check, so the closure silently inherits @MainActor and the isolation assert fires AT RUNTIME on the framework's queue — `dispatch_assert_queue_fail` → SIGTRAP in Release. This exact bug shipped in build 2.1(1) and crashed App Store review twice: the `installTap` audio-tap closures in `AudioRecorder.start` and `LectureRecorder` were formed on the main actor and invoked on AVFAudio's RealtimeMessenger queue. Rule: form such closures in `nonisolated` functions or inside `Task.detached`, or mark them `@Sendable` explicitly (extracting non-Sendable framework objects into plain values before any MainActor hop).
- **Never host `UIColorPickerViewController` inside a SwiftUI popover or a sheet of one.** The eyedropper's screen-sampling tap dismisses the popover, UIKit's `_pickerDidDismissEyedropper` then re-presents into the destroyed hierarchy → `NSInvalidArgumentException` (shipped crashes, builds 2.1(1) + 2.1(3)). Use `CustomColorPickerPresenter` (UIKit formSheet from the top-most view controller) — see `ColorPickerView.swift`.
- **Note text typography has ONE source of truth**: `DesignSystem/NoteTypography.swift` (shared body size in page points, line spacing, paragraph spacing, role-matched kern, eyebrow tokens). `RichTextController.defaultAttributes` (iOS) and `MacRichTextCodec.defaultTypingAttributes` (Mac) both consume it — never hardcode a font for page text, and never let the platforms drift to different body sizes (a page is one shared point space). Use `lineSpacing` (ratio-based), never `lineHeightMultiple` — the multiplier inflates the caret and selection rects and reads as a broken cursor.

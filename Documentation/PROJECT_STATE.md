# Project State

_Kept short and current. Any LLM opening this repo should read this file first, then [`CODE_GRAPH.md`](CODE_GRAPH.md) for a structural map._

Last updated: 2026-07-07

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
3. **Mac meeting assistant.** "Meeting Transcription" streams words into
   the page; on stop, `MacMeetingSummary` distills the transcript with
   on-device Apple Intelligence (chunked map-reduce) and inserts a
   "SUMMARY" block ABOVE the first transcript block. All failures degrade
   to transcript-only, never an error state on the page.

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

**When SwiftData behaves oddly:**
- `StorageService.purgeDuplicateRows()` and `reconcileSoftDeleteFlags()` run on library appear — recent duplicate-ID crash was fixed by making every SwiftData-fed `ForEach` tolerate duplicates (see commit `d629830`).

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

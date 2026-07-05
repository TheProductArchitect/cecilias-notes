# Project State

_Kept short and current. Any LLM opening this repo should read this file first, then [`CODE_GRAPH.md`](CODE_GRAPH.md) for a structural map._

Last updated: 2026-07-05

## Elevator pitch

Cecilia's Notes is a Zara-editorial handwriting-first note-taking app. Two Xcode targets share one SwiftUI codebase over a SwiftData + CloudKit store, with MultipeerConnectivity for local peer sync:

- `CeciliasNotes` — iPad + iPhone (primary; handwriting on iPad only)
- `CeciliasNotesMac` — Mac companion (read strokes, edit everything else)

Universal Purchase, shared bundle id `app.ceciliasnotes`, shared CloudKit container `iCloud.app.ceciliasnotes`, shared App Group `group.app.ceciliasnotes`.

## Current phase

**Mac companion, verification pass.** Build is green on both targets. Awaiting user smoke test of four recent fixes:

1. **Onboarding personalisation** — 3-step Mac flow (`name → sync → done`) using the shared `PersonalIdentity.nameKey`, `validateName`, `mirrorNameToAppGroup`. Live `BrandWordmark` preview. Same possessive contract as iPad.
2. **Editorial sync banner** — replaced the intrusive floating "not signed in" strip with an inline 8pt tracked-uppercase hairline between masthead and content, matching `DateEyebrow` aesthetic.
3. **Settings** — `⌘,` opens `Settings { MacSettingsView() }` via `CommandGroup(replacing: .appSettings)` + a `.macOpenSettings` `NotificationCenter` hop that `MacAppDelegate` routes to `NSApp.sendAction(Selector(("showSettingsWindow:")))`.
4. **Typing on Mac** — double-click on an empty page inserts a text element at the click point; italic hint "double-click to type — handwriting stays on iPad" while page is empty. Existing `⌘T` still works.

Deleted the "Handwriting is iPad-only" toolbar pill — a permanent Post-It in the chrome. That constraint now lives in the empty-state hint and Settings → About only.

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
    ├── Editor/MacEditorView.swift Mac page editor (no strokes, typed text + PDF only)
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

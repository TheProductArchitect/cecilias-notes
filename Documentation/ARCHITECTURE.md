# Cecilia's Notes — Architecture

A reference document for the development team. Bullet points and short
paragraphs are preferred over prose; this is a reference, not a tutorial.

> **New here?** Start with [`PROJECT_STATE.md`](PROJECT_STATE.md) for the
> current phase + debug playbook, then skim [`CODE_GRAPH.md`](CODE_GRAPH.md)
> for the auto-generated file/type/notification map. Regenerate the graph
> after structural changes with `python3 Documentation/tools/build_code_graph.py`.

---

## App overview

- **Cecilia's Notes** — handwriting-first note-taking for iPad with
  on-device intelligence.
- **Deployment target:** iOS 18.4. iPad only (`TARGETED_DEVICE_FAMILY`
  set in build settings).
- **Stack:** Swift (Swift 5 language mode — see *Swift 6 migration
  status* below) + SwiftUI + UIKit (hybrid). PencilKit for ink,
  Vision for OCR, Speech for transcription, Foundation Models (gated)
  for AI, CloudKit Database via SwiftData for sync, WidgetKit for the
  home and lock screen tiles.
- **Zero third-party dependencies.** Everything is an Apple framework.
- **Local-first.** No network calls, no backend, no analytics, no
  telemetry. Sync goes through the user's own iCloud account. The
  Foundation Models inference runs on-device.

Internal Swift identifiers, file paths, target names, and the Xcode
module are all named `CeciliasNotes`. The original `Ink` name is
retained only where it is a stable identifier with persistent meaning
outside the codebase: the `ink://` URL scheme, the
`iCloud.com.wave.venu.Ink` CloudKit container, the
`group.com.wave.venu.Ink` App Group, `Application Support/Ink/` as
the on-disk data root, `ink.*` UserDefaults keys, and the schema
family (`InkSchemaV1`…`V5`, renamed atomically with the next V6 bump).
User-facing copy is "Cecilia's Notes".

---

## Data layer

### SwiftData models

```
Subject ─┬─ Folder (optional, depth ≤ 3)
         └─ Notebook ── Page ─┬─ TextBlock
                              ├─ MediaAttachment
                              └─ AudioAnnotation
```

Every relationship is bidirectional with `inverse:`, every to-many
collection is optional (`[Page]?`), and every non-optional attribute
has an inline default. Those three properties are CloudKit's hard
requirements; violating any of them crashes the container.

Each model exposes a raw UUID foreign key alongside the
`@Relationship` reference (e.g. `Page.notebookId` next to
`Page.notebook`). `StorageService` writes both in lockstep on every
create / move; read paths can use whichever fits.

### Soft delete + 30-day reaper

- Every model carries `isDeleted: Bool` and `deletedAt: Date?`.
- Delete sets the flag and stamps the date; the record is filtered
  out by every fetch (`isDeleted == false`).
- `StorageService.purgeExpiredDeletedRecords()` hard-deletes
  records whose `deletedAt` is older than 30 days; the related file
  assets (`media/`, `audio/`, `source.pdf`, `exports/`) are removed
  with the notebook directory, and every side-channel store is
  `forget(pageIds:)`-ed in the same pass.
- `emptyTrash()` runs the same purge for everything currently
  flagged, ignoring the 30-day cutoff.

### Schema migration

- One canonical schema (`InkSchemaV4`). The earlier V2/V3/V4
  staged-migration setup tripped SwiftData's `Duplicate version
  checksums detected` crash because every version referenced the
  same Swift model types — the checksums collided.
- **Additive-only column changes are allowed inside V4.** Adding a
  new property is safe as long as every non-optional default is
  inline-initialised.
- **Introducing a new model type requires a new schema version with
  structurally-distinct Swift types** (per-version namespace, renamed
  class) so the derived checksums diverge. Don't reuse the same
  Swift type across two versions.

### CloudKit sync

- `ModelContainer` is opened with `cloudKitDatabase:
  .private("iCloud.com.wave.venu.Ink")`.
- Conflict resolution is CloudKit's native last-write-wins; there
  is no custom merge logic.
- `Info.plist` carries `audio` + `remote-notification` under
  `UIBackgroundModes`. The latter is mandatory for CloudKit silent
  push.
- The entitlements file declares `CloudKit` + `CloudDocuments` and
  pins the container + ubiquity identifiers.
- `ModelContainer.inkContainer()` falls back to local-only
  (`cloudKitDatabase: .none`) if CloudKit init throws — the user
  sees a non-syncing app rather than a crash, and Settings → iCloud
  surfaces the sign-in prompt.

---

## Side-channel stores (UserDefaults)

New per-notebook / per-page state lives in UserDefaults rather than
SwiftData. Two reasons:

1. Adding a property to a pinned schema version trips the
   duplicate-checksum crash documented above unless we also bump the
   schema, and bumping is expensive.
2. The data is non-syncing by design (per-device UI state) or is a
   sidecar that should not affect the SwiftData record.

Every store is wiped from `StorageService.purgeNotebookFiles` so the
30-day reaper doesn't leave orphans.

| Store | Key prefix | Stores | Why not SwiftData |
|---|---|---|---|
| `CoverToneStore` | `app.notebooks.coverTone` | `Notebook.coverTone` | Schema |
| `NotebookPreferencesStore` | `app.notebooks.preferences.v1` | `autoAddPagesOnScroll`, `autoHideHeader` | Schema |
| `PDFBackingStore` | `app.notebooks.pdfBackedPages.v1` | Page → source PDF index map | Schema |
| `StickyNoteStore` | `app.stickyNotes.v1` | Sticky notes (id / pos / body / soft-delete) | New annotation type, schema |
| `LectureStore` | `lecture.store.v1` | `LectureRecord` (audio path, transcript, duration) | New annotation type, schema |
| `RecentNotebooksTracker` | `app.recents.notebooks` | id → last-opened timestamp | Schema |
| `IntelligenceCache` (summaries) | `intelligence.summaries.v1` | Per-notebook summary + generation timestamp | Cache, ephemeral |
| `IntelligenceCache` (dismissed tags) | `intelligence.tagsDismissed.v1` | Set of notebook ids whose suggestion banner was dismissed | UI flag |
| `IntelligenceCache` (embeddings) | `Documents/embeddings/<uuid>.bin` | `[Float]` per notebook | Binary file, not k/v |
| `AppGroupLaunchTracker` | App Group `app.launch.lastOpenDate` | Wall-clock launch time | Shared with widget |
| `WidgetDataWriter` snapshot | App Group `ink_widget_data.json` | Recents snapshot | Shared with widget |

App Group suite: `group.com.wave.venu.Ink`. All other stores use
`UserDefaults.standard`.

---

## Service layer

One paragraph each. "Owns" = what it writes / mutates. "Does NOT"
calls out work that someone else handles.

- **`StorageService`** — Singleton, `@MainActor`. Owns the SwiftData
  `ModelContext`, every model-mutation path, and the
  `notebook/<uuid>/{media,audio,exports,source.pdf}` filesystem
  layout. Does NOT own search index state, AI caches, the lecture
  recorder, or the widget snapshot. Every `create*` writes both the
  raw UUID FK and the `@Relationship` reference so CloudKit can
  resolve cross-device references.

- **`SearchIndexService`** — Singleton, `@MainActor`. Owns the
  per-notebook search index (`Documents/search_index.json`), the
  Spotlight donation queue, and the OCR scheduler. Index loads
  off-main via `loadAsync()` from RootView's `.task` modifier;
  every read/write entry point early-returns until `isLoaded` is
  true. 10MB cap drops handwriting OCR text first; titles, text
  blocks, transcripts, and lecture transcripts are preserved.
  Does NOT touch Vision or Foundation Models directly — those
  belong to `HandwritingOCRService` and `IntelligenceService`.

- **`IntelligenceService`** — Singleton, `@MainActor`,
  `ObservableObject`. Owns `LanguageModelSession` access for
  summary / title / tag / Ask-My-Notes generation. Gated by
  `canRun = isAvailable && intelligenceEnabled`. Every call site
  must short-circuit to complete UI absence when `canRun` is
  false. Does NOT own the summary cache — that's `IntelligenceCache`.

- **`HandwritingOCRService`** — Stateless enum. Owns the Vision
  rasterise + recognise pipeline for a `PKDrawing`. Returns
  `[Line]` with normalised origins. Runs entirely off the main
  thread (rasterisation and Vision both happen on a utility
  dispatch queue). Does NOT persist results — the caller
  (`SearchIndexService`) stores them.

- **`SpotlightService`** — `actor`. Owns the `CSSearchableIndex`
  donation queue with a 5-second debounce. Does NOT decide what
  text to surface; the caller passes a fully-built attribute set.

- **`ExportService`** — Static. Owns the PDF / images export
  pipelines plus the `exports/` directory bookkeeping. PDF
  rendering and file writes happen off-main via
  `Task.detached`. Does NOT own the share sheet UI.

- **`LectureRecorder`** — `@MainActor`, `ObservableObject`. Owns the
  audio engine, the `.m4a` file write, the speech recognition
  rotation loop, and the live transcript. The AVAudioEngine tap
  callback hands captured buffers to a separate
  `AudioCaptureActor` so MainActor isolation isn't crossed from
  the engine queue. Does NOT own search indexing of the resulting
  transcript — that flows through `LectureStore` →
  `SearchIndexService.rebuildSynchronousMetadata`.

- **`CloudSyncManager`** — `@MainActor`, `ObservableObject`. Owns
  the iCloud Drive (ubiquity-container) file-presence sync that
  surfaces notebooks in the Files app. Independent of the
  CloudKit Database sync used by SwiftData; both are enabled
  simultaneously when iCloud is on.

---

## Architectural rules

These are non-negotiable. Violations should be flagged with
`// AUDIT:` and surfaced in PR review.

- **`@Query` for rendering, `StorageService` for one-shot reads.**
  SwiftUI views that need reactive updates use `@Query`; service
  code that needs a value once uses `StorageService.fetch*` and
  drops the result.
- **No new SwiftData entity types without a documented schema
  migration plan.** Adding a model means a new `VersionedSchema`
  with structurally-distinct Swift types. Adding properties to an
  existing model is safe.
- **No network calls. No backend. No data leaves the device.**
  Every framework used (Vision, Speech, Foundation Models) runs
  on-device. CloudKit is the user's own iCloud account.
- **All heavy work off the main actor.** OCR, AI generation, PDF
  mutation, audio file I/O, and large JSON encodes run on
  `Task.detached` or `DispatchQueue.global`. UI mutations always
  hop back to the main actor.
- **Side-channel stores use `UserDefaults.standard` (or the App
  Group suite for cross-target stores), keyed with a documented
  prefix, and are cleaned up in
  `StorageService.purgeNotebookFiles`.**

---

## Feature flags

- **`IntelligenceService.canRun`** = `isAvailable && intelligenceEnabled`.
  - `isAvailable` is true only when `canImport(FoundationModels)`
    succeeds AND `if #available(iOS 26.0, *)` AND
    `SystemLanguageModel.default.availability == .available`. At
    the current iOS 18.4 deployment target, this resolves to
    `false` on every device until the deployment moves up.
  - `intelligenceEnabled` is the user-facing master toggle in
    Settings → Intelligence. Defaults to `true` via
    `UserDefaults.register(defaults:)`.
  - When `canRun` is false, every AI surface must collapse to
    complete UI absence: no disabled states, no placeholders, no
    spinners. The Settings rail also hides the Intelligence
    section.

---

## Widget architecture

- **App Group:** `group.com.wave.venu.Ink`. Shared between the main
  app and the `CeciliasNotesWidget` extension target.
- **Written by the main app:**
  - `ink_widget_data.json` — the recents snapshot. Written by
    `WidgetDataWriter` (debounced via
    `StorageService.scheduleWidgetSnapshot`).
  - `user.displayName` — the user's name for the brand mark.
    Written by `PersonalIdentity.mirrorNameToAppGroup` at every
    name-commit site.
  - `app.launch.lastOpenDate` — splash-skip anchor, written by
    `AppGroupLaunchTracker.markOpened` on every launch.
- **Read by the widget extension:**
  - `CeciliasNotesWidgetProvider` reads the recents JSON on every timeline
    request (default 15-minute refresh, plus explicit reloads from
    the main app's save path).
  - Each widget's `BrandPossessive` and `GhostLetter` views read
    `user.displayName` via `@AppStorage(store:)` against the App
    Group suite.
- **Five widget configurations** (see `NewNoteWidget.swift` for the
  source of truth):
  - `HomeSmallNewNoteWidget` (`.systemSmall`)
  - `HomeMediumRecentsWidget` (`.systemMedium`)
  - `LockCircularNewNoteWidget` (`.accessoryCircular`)
  - `LockRectangularLastNotebookWidget` (`.accessoryRectangular`)
  - `LockInlineRecentWidget` (`.accessoryInline`)
- **Tap targets:**
  - Quick capture → `ink://quick-capture`
  - Open notebook → `ink://open/{uuid}`
  - Both routed by `DeepLinkRouter` in the main app.

---

## Known deferred items

These are documented `// AUDIT:` / FIXME flags that the next pass
should address. None are bugs; all are explicit deferrals.

- **`IntelligenceService.embed(text:)`** — stubbed. Returns `nil`
  pending the verified Foundation Models embedding entry point.
  `SearchIndexService.backfillEmbeddingsIfNeeded` is therefore a
  no-op and semantic search degrades to keyword-only. Wire when
  iOS 26 deployment is practical.
- **PDF annotations Pass B/C** — text highlights, underline,
  strikethrough, annotation list. Pass A (sticky notes) is shipped.
- **Lecture mode Pass B** — Foundation Models summary,
  `LectureBlockView`, expandable transcript. Pass A (record + live
  transcript + search indexing) is shipped.
- **App Store prep** — `CFBundleDisplayName` and `CFBundleName` are
  set, but AppIcon asset-catalogue coverage must be confirmed
  before submission (`AppIcon` plus 26 letter variants at every
  iOS-required size).
- **`AVAudioPCMBuffer` deep-copy cost** — every audio tap callback
  deep-copies the buffer before crossing the `AudioCaptureActor`
  boundary. At ~10 callbacks/sec the cost is negligible, but if
  the buffer size grows (e.g. stereo, higher sample rate) this
  could be revisited with a serial-queue-backed Sendable wrapper.

---

## Editor "magnetic" geometry

The continuous canvas leans on a few snapping behaviours so the
document feels sticky rather than free-floating. The view-independent
math lives in **`Features/Editor/Canvas/MagneticSnapMath.swift`** so it
is unit-testable without a live `UIScrollView` (see
`MagneticSnapMathTests`); `ContinuousCanvasView` is a thin adapter that
feeds it scroll geometry and page frames.

- **Cross-page element hand-off** (`resolveCrossPage`). Dragging an
  image/shape/sticky off the top or bottom of its page hands it to a
  sibling page. Strict containment when the drop lands inside a page;
  a **nearest-edge magnetic fallback** when it lands in the inter-page
  gutter or past the first/last page — it snaps to the END of the page
  above the gap or the BEGINNING of the page below, whichever edge is
  closer. Before this, a gutter drop found no containing page and the
  element reverted to its origin.
- **True centring** (`applyContentInset`). The page is centred with
  symmetric left/right insets at every zoom where it fits, collapsing
  to 0 once it overflows the viewport (zoomed in) so it can scroll
  flush to either edge. An earlier version reserved the tool-palette
  strip on one side so the floating pill wouldn't cover the page edge,
  but a one-sided reservation is asymmetric and pushed a fitted page
  off-centre ("the notebook isn't centred"). The palette is a small
  draggable pill floating over the canvas; overlapping the page edge
  is a better trade than an off-centre page.
- **Zoom membership throttle.** `scrollViewWillBeginZooming` sets the
  same "actively interacting" flag a scroll fling uses, so canvas /
  overlay membership throttles (~10 Hz) and defers unmounts during a
  pinch instead of churning mount→unmount→mount every tick — that
  churn was the "text flickers while zooming in/out" report. The
  `scrollViewDidEndZooming` settle runs the full pass.
- **Edge + zoom rest-point snapping** (`snapToEdgesIfClose`,
  `scrollViewDidEndZooming`). Releasing a pan/zoom within ~44pt of a
  viewport edge clicks flush to it; zoom deceleration magnetises to
  1.0× or the fit-to-width scale; and a page that fits horizontally
  always recentres (no threshold — there is one valid resting X).

## Element layers (z-order)

`PageElement`s carry a `zIndex`; same-kind elements render in that
order inside their shared overlay (`PageElementOverlayFetch` sorts by
it). **Bring to Front / Send to Back** (image element's floating
toolbar) reorder an element among its **same-kind** siblings via
`PageElementOrdering` (`Features/Editor/Canvas/`) — pure `newZIndex`
math (unit-tested in `PageElementOrderingTests`) plus a `@MainActor
apply` that registers undo, saves, and posts the kind's overlay-refresh
notification. Cross-kind stacking (image vs text) is fixed by
`PageOverlaysContainer`'s ZStack order and is deliberately not
reorderable; strokes live in the `PKCanvasView` above all overlays and
are not part of the element z-stack. Extending the control to shapes /
sticky notes is just wiring their toolbars to the same
`PageElementOrdering.apply`.

## Active investigations

Open, unresolved bugs are tracked in **`OPEN_ISSUES.md`** — each with
symptom, failed prior attempts, the diagnostic in place, and the next
step. Currently open: element-tap gesture absorption, the iOS 26
alternate-icon swap, the Swift 6 warnings (below), the dictation
view-update warnings, and the accepted-for-now translucent-ink
opacity (#10) and editor-scroll smoothness (#11) items.

---

## Swift 6 migration status

**Honest accounting (verified 2026-05-20).** The project builds in
the **Swift 5 language mode** — `SWIFT_VERSION = 5.0` in all eight
build configurations. It has *not* been moved to Swift 6 mode.

Commit `f69c6ac` ("Swift 6 actor isolation cleanup — zero errors
under SWIFT_VERSION=6") is accurate on the narrow claim it makes:
building with `xcodebuild … SWIFT_VERSION=6` succeeds with **zero
errors**. But the commit *title* overstates completeness — the
cleanup is partial:

- The project's own build setting was never changed to `6.0`, so
  the app ships compiled in Swift 5 mode.
- Building under `SWIFT_VERSION=6` still emits **37 strict-concurrency
  warnings**. They are warnings (not errors) in Swift 6 mode, so the
  build passes — but they would need resolving before the project
  could adopt Swift 6 mode as a clean baseline.

No user-visible impact in the current Swift 5 build.

### Outstanding warning sites (37, under `SWIFT_VERSION=6`)

| File | Count | Pattern |
|---|---|---|
| `CloudSyncManager.swift` | 15 | main-actor `value` referenced from a `Sendable` closure |
| `PDFPagePickerSheet.swift` | 6 | `PDFDocument` is not `Sendable`; `Task.value` crossing main-actor isolation |
| `ContinuousCanvasView.swift` | 5 | main-actor `shared` / `hasPencil` / `fingerDrawingEnabled` from `Sendable` closures + nonisolated calls |
| `ExportService.swift` | 2 | unnecessary `nonisolated(unsafe)` on a `Sendable` `UIImage` |
| `PDFDerivedExport.swift` | 2 | unnecessary `nonisolated(unsafe)` on a `Sendable` `UIImage` |
| `EditorViewModel.swift` | 2 | nonisolated call to `refreshPencilDoubleTapActionFromUserDefaults()`; redundant `await` |
| `MediaPickerPresenter.swift` | 1 | mutation of captured `var` in concurrent code |
| `MediaPickerController.swift` | 1 | mutation of captured `var` in concurrent code |
| `AudioRecorder.swift` | 1 | `AVAudioPCMBuffer` captured in a `@Sendable` closure (+ `@preconcurrency` hint) |
| `SpeechTranscriber.swift` | 1 | nonisolated call to a main-actor initializer |

The `ExportService` / `PDFDerivedExport` redundant-annotation sites
and the `EditorViewModel` redundant `await` are mechanical. The
`PDFPagePickerSheet`, `MediaPicker*`, and `AudioRecorder` sites are
genuine concurrency-boundary work (non-`Sendable` Apple types,
captured-`var` races) and need careful restructuring with the
media / audio paths exercised — bigger than a focused commit.

**Plan:** complete the cleanup and flip `SWIFT_VERSION` to `6.0` as
a dedicated commit once the media/audio concurrency restructuring
can be tested properly. Until then this section is the source of
truth — not the `f69c6ac` commit message.

---

## File layout

```
CeciliasNotes/CeciliasNotes/                    Main app target
├── App/                    @main, RootView, DeepLinkRouter
├── Core/
│   ├── Models/             @Model classes + InkSchemaV4
│   ├── Services/           StorageService, SearchIndexService, …
│   ├── Extensions/         ModelContainer+CeciliasNotes, etc.
│   └── Utilities/          TagValidator, NameFormatter, …
├── Features/
│   ├── Library/            Home grid, search, ask sheet
│   ├── Editor/             Canvas, toolbar, lecture, annotations
│   ├── Settings/           Sectioned settings UI
│   ├── Onboarding/         First-launch flow
│   ├── Splash/             Cold-launch animation
│   └── Export/             PDF + image export pipelines
├── DesignSystem/           Colours, typography, components
└── Resources/              Info.plist, entitlements, AppIcons, fonts

CeciliasNotes/CeciliasNotesWidget/              Widget extension target
└── NewNoteWidget.swift     The five widget configurations

CeciliasNotes/CeciliasNotesMac/                 Mac companion target
├── CeciliasNotesMacApp.swift   @main scene
├── MacRootView.swift           library shell + masthead
├── MacToolbar.swift            CommandGroup + menu notifications
├── Editor/
│   ├── MacEditorView.swift     continuous canvas, page strip, focus mode
│   ├── MacRendering.swift      element overlays (text, image, sticky, audio, PDF)
│   ├── MacEditing.swift        insert helpers + text/sticky editor sheets
│   ├── MacRichTextEditor.swift NSTextView + MacRichTextCodec (shared archive)
│   ├── MacElementTransform.swift  drag + corner-resize
│   └── MacMinimapView.swift    zoom minimap
├── Export/                     MacExportSheet (+ NSSharingServicePicker share)
└── Services/                   MacImportService, MacHandoff, …
```

Shared Core / DesignSystem / Library / Sync folders compile into both
targets via `PBXFileSystemSynchronizedRootGroup` with per-folder
`membershipExceptions` (iPad-only overlays excluded on Mac). Mac never
authors strokes — PencilKit canvas is read-only; typed text, stickies,
images, shapes, audio, and PDF elements are editable.

See [`MAC_APP_PRD.md`](MAC_APP_PRD.md) and [`PROJECT_STATE.md`](PROJECT_STATE.md)
for rollout status and debug playbook.

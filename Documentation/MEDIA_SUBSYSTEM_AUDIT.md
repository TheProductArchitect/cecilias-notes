# Media subsystem audit

**Status:** read-only audit. No code has been changed for this document. All
findings are derived from grep + targeted file reads. Line numbers are accurate
as of the commit this was produced against.

This document supports a coordinated structural fix pass. The user has asked
for the analysis surfaced **before** any refactoring — read it, push back on
anything that's wrong, and confirm scope before code changes.

The bugs prompting the audit:
1. Inserted images render as a grey box.
2. Lecture / audio cards appear above the page, hidden, untappable.
3. Apple Pencil hover shifts existing strokes down.
4. Apple Pencil double-tap glitches.

The surface-level fixes for #1, #2, #3, and #4 in the previous iteration each
revealed the next layer. The pattern below explains why: the media subsystem
has **drifted into three incompatible coordinate spaces, two storage
strategies, and three independent overlay-mounting models**. A single
coordinate or storage decision in any one feature can land on the wrong axis
of any of those grids and produce a "feature is broken" symptom that looks
isolated but isn't.

---

## 1. Overlay layers

The editor canvas hierarchy, top-to-bottom (front-to-back rendering, hit-test
walks back-to-front so taps are tried in reverse):

| # | Layer | File | Mounted in | Coordinate space | Storage |
|---|---|---|---|---|---|
| 1 | `PKCanvasView` (per page, lazy in warm band) | [ContinuousCanvasView.swift:787](Ink/Ink/Features/Editor/Canvas/ContinuousCanvasView.swift#L787) | `contentView` (above its renderer) | Page renderer's frame (effective height incl. extra-height extension) | `Page.strokeData: Data` (PKDrawing serialised) — SwiftData `@Model` |
| 2 | `LectureBlocksOverlayView` (per page) | [LectureBlockView.swift:249](Ink/Ink/Features/Editor/Lecture/LectureBlockView.swift#L249) | Inside each `PageRenderer` | Receives `pageSize` = `CGSize(baseSize.width, **effective height**)` from parent — line 572 of ContinuousCanvasView | TextBlock with `content == "lecture:<uuid>"` (SwiftData) + `LectureRecord` (UserDefaults JSON) |
| 3 | `AudioAnnotationPinsOverlayView` (per page) | [AudioAnnotationPinsOverlayView.swift](Ink/Ink/Features/Editor/Audio/AudioAnnotationPinsOverlayView.swift) | Inside each `PageRenderer` | `GeometryReader.proxy.size` — resolves to renderer.bounds, i.e. effective height | `AudioAnnotation` (SwiftData), audio file on disk |
| 4 | `ImageAttachmentsView` (per page) | [ImageAttachmentsView.swift](Ink/Ink/Features/Editor/Media/ImageAttachmentsView.swift) | Inside each `PageRenderer` | Receives `pageSize` = `baseSize` (page's `pointSize`) explicitly | `MediaAttachmentRecord` (UserDefaults JSON) + JPEG file on disk |
| 5 | `TemplatePatternView` (per page) | [TemplatePatternView.swift](Ink/Ink/Features/Editor/Canvas/TemplatePatternView.swift) | Inside each `PageRenderer` (autolayout to renderer bounds) | Renderer bounds (effective height) | None (rendered from `Page.backgroundTemplate`) |
| 6 | `PageRenderer` (paper + PDF backing) | [PageRenderer.swift](Ink/Ink/Features/Editor/Canvas/PageRenderer.swift) | `contentView` | Page renderer's own frame (effective height) | `Page.pdfPageIndex` + `Notebook.sourcePDFURL`, plus `PDFTextAnnotationStore` |
| 7 | `StickyNotesOverlayView` (single, floating) | [StickyNotesOverlayView.swift:20](Ink/Ink/Features/Editor/Annotations/StickyNotesOverlayView.swift#L20) | `overlayLayer` (full content view, all pages) | `GeometryReader.proxy.size` — **full content view size, all pages stacked** | `StickyNoteStore` (UserDefaults JSON) |
| 8 | `TextBlockOverlayView` (single, floating) | [TextBlockOverlayView.swift](Ink/Ink/Features/Editor/TextBlocks/TextBlockOverlayView.swift) | `overlayLayer` | Reads `viewModel.currentPage.pageSize.pointSize` (base size) but lives in the full-content-view rect | TextBlock (SwiftData) |

**Three different mounting models, all in one canvas:**

- **Per-page inside renderer** (Lecture, AudioPins, Images, Template): each
  page renderer owns its own `UIHostingController` for that overlay. Scrolls
  with the page mechanically. Child overlays inherit the renderer's
  coordinate space.
- **Single overlay covering all pages stacked** (StickyNotes): one
  hosting controller mounted to `overlayLayer`. Its coordinate space is the
  entire stacked content view.
- **Single overlay floating with active page** (TextBlocks): one hosting
  controller in `overlayLayer`, but its content reads
  `viewModel.currentPage` and renders only that page's blocks. Coordinate
  space is "wherever the active page happens to be in content-view coords".

The drift: each of those three models was introduced for a specific feature
and copied with mods for the next one. There's no single "place an annotation
on page X at normalised (x, y)" primitive.

---

## 2. Coordinate spaces

Every spatial value in the editor lives in one of these spaces. Conversions
between them are done ad hoc at each call site.

| Space | Origin | Units | Stable? | Used by |
|---|---|---|---|---|
| **Base page size** (`Page.pageSize.pointSize`) | top-left of paper | points | yes — derived from a tiny enum of fixed paper sizes | `ImageAttachmentsView` (good), `TextBlockOverlayView` (questionably) |
| **Effective page size** = base size + `PageExtraHeightStore.extraHeight(forPageId:)` | top-left of paper | points | **no** — grows whenever `extendLastPage` fires after a stroke commit | `LectureBlocksOverlayView` (gets effective in its `pageSize` parameter), `AudioAnnotationPinsOverlayView` (gets effective via GeometryReader), `PageRenderer.frame`, `PKCanvasView.frame` |
| **Content view space** (the scroll view's content) | top-left of first page | points | grows when pages add/extend | `StickyNotesOverlayView` (full-content GeometryReader), scroll offset math |
| **Scroll-view bounds** (visible viewport) | top-left of viewport | points | changes constantly with scroll | scroll-driven warm-band + active-page detection |
| **Screen / window** | UIWindow top-left | points | stable per-orientation | `UIPencilInteraction` events (rarely surfaced — handled by interaction itself) |
| **Normalised page** (0–1) | page top-left | dimensionless | yes — the most stable of all | `MediaAttachmentRecord.normalizedX/Y/W/H`, `StickyNoteRecord.normalizedX/Y`, `AudioAnnotation.pageX/Y`, `TextBlock.x/y/width/height` |

**The drift, concretely:**

- `MediaAttachmentRecord` stores `normalizedX/Y/W/H`. `ImageAttachmentsView`
  multiplies by `pageSize` (which it correctly receives as **base** size).
  Result: image stays anchored to its original page coordinate even when the
  page extends. ✅
- `LectureBlocksOverlayView` is passed
  `CGSize(baseSize.width, **effectiveHeight**)`
  ([ContinuousCanvasView.swift:572](Ink/Ink/Features/Editor/Canvas/ContinuousCanvasView.swift#L572))
  and computes positions as `block.y * pageSize.height`. When the last page
  extends, **a lecture card on that last page jumps downward** by the same
  proportion as the extension. The block's stored `y` was relative to the
  base size, but render uses effective.
- Same problem for `AudioAnnotationPinsOverlayView` — it uses
  `GeometryReader { proxy in let pageSize = proxy.size }`. The proxy size is
  the renderer's bounds, which is effective height. Pin positions drift
  downward when the page extends.
- `StickyNotesOverlayView` lives in **content-view space, not page space**.
  `proxy.size = contentView.size` — that's the entire stacked notebook. Its
  `note.normalizedX/Y` is multiplied by content view size, which produces an
  absolute coordinate **in the entire stacked content view**, not within a
  specific page. This works only because the StickyNoteRecord's normalised
  values are interpreted as "fraction of content view" rather than "fraction
  of page" — which is a different contract than every other store. (Or it's
  silently broken when there are multiple pages — needs verification.)
- `TextBlockOverlayView` reads `viewModel.currentPage.pageSize.pointSize`
  (base) but it's mounted on `overlayLayer` which has full-content frame. So
  its `.frame(width: pageSize.width, height: pageSize.height)` clips to one
  page worth of area in the top-left corner of the content view. Text blocks
  display correctly only because the user scrolls them into view —
  positioning is happening in "first-page coords" regardless of which page
  is actually active.

**Where the bugs land:**

| Bug | Coordinate root cause |
|---|---|
| Lecture card above the page | Card's intrinsic SwiftUI `.position(...)` centring — **fixed in previous pass** but the underlying issue (using effective height for placement math) remains for any future placement logic. |
| Audio pin drifts when page extends | Per-page renderer effective-height vs. base-height mix-up. |
| Image stays put when page extends | Correctly uses base size. ✅ |
| Sticky notes on multi-page notebook | Likely silently using content-view coordinates as if page coordinates. Untested by the user (single-page notebooks dominate the manual test path). |

---

## 3. Storage mechanisms

Two distinct persistence systems coexist, with content split inconsistently
across them.

### 3.1 SwiftData entities (`@Model`)

| Entity | Stores | File path |
|---|---|---|
| `Notebook` | title, pages, cover meta | [Core/Models/Notebook.swift](Ink/Ink/Core/Models/Notebook.swift) |
| `Subject` | folder grouping for notebooks | [Core/Models/Subject.swift](Ink/Ink/Core/Models/Subject.swift) |
| `Page` | strokeData (PKDrawing bytes), template, pageSize, pdfPageIndex | [Core/Models/Page.swift](Ink/Ink/Core/Models/Page.swift) |
| `TextBlock` | x/y/w/h normalised, content (string), zIndex, richTextData (NSAttributedString archive) | [Core/Models/TextBlock.swift](Ink/Ink/Core/Models/TextBlock.swift) |
| `AudioAnnotation` | pageX/Y normalised, durationSeconds, transcription, fileName, isTranscribed, amplitudeData | [Core/Models/AudioAnnotation.swift](Ink/Ink/Core/Models/AudioAnnotation.swift) |
| `MediaAttachment` | (legacy SwiftData entity) | [Core/Models/MediaAttachment.swift](Ink/Ink/Core/Models/MediaAttachment.swift) — **declared but unused at runtime** per [MediaAttachmentRecord.swift:11](Ink/Ink/Core/Models/MediaAttachmentRecord.swift#L11) ("remains in the schema for CloudKit compatibility but is not used at runtime for image data") |

Schema is frozen at V3. Adding a new `@Model` type collides with SwiftData's
"Duplicate version checksums detected" — see comment in `InkSchemas.swift`.
**This is why every new annotation kind ends up in a UserDefaults
side-channel.** That constraint is real and shapes everything below.

### 3.2 UserDefaults JSON side-channel stores

All keyed by `pageId.uuidString`, all use the same JSON-dictionary-of-arrays
shape, all post a Notification.Name on mutation.

| Store | UserDefaults key | What it stores | Bytes? |
|---|---|---|---|
| `MediaAttachmentStore` | `media.attachments.v1` | `[MediaAttachmentRecord]` — id, normalised rect, rotation, file path **only metadata** | No. JPEG bytes go to disk. |
| `StickyNoteStore` | `app.stickyNotes.v1` | sticky note records | small (text only) |
| `LectureStore` | `lecture.store.v1` | `[LectureRecord]` — id, audioRelativePath, transcript, summary, durationSeconds | text only — audio bytes go to disk |
| `PDFTextAnnotationStore` | `pdf.text.annotations.v1` | PDF highlight/underline records | small |
| `PDFBackingStore` | (similar) | PDF document references | small |
| `PageExtraHeightStore` | `ink.page.extraHeight.<uuid>` | per-page double | trivial |
| `NotebookPreferencesStore` | various | per-notebook prefs | small |
| `CoverToneStore` | (similar) | per-notebook cover tint | small |

**UserDefaults size pressure:** each individual store stays under tens of KB
because no store puts media bytes in. The architectural rule is observed by
every store. This is correct and not the bug source for #1.

### 3.3 Filesystem layout (the real source of #1's drift)

Three different directory roots, all writable:

```
Documents/
├── media/
│   └── <notebookId>/
│       └── <attachmentId>.jpg          ← MediaAttachmentRecord.relativeFilePath
├── Notebooks/
│   └── <notebookId>/
│       ├── audio/
│       │   ├── <annotationId>.m4a      ← AudioAnnotation, by StorageService.audioURL(for:)
│       │   └── lecture_<recordId>.m4a  ← LectureRecord.audioRelativePath
│       ├── media/                      ← (StorageService.mediaDir — different from /Documents/media/)
│       └── exports/
└── …
```

Two separate `media/` directories on disk, owned by different code paths:
- `Documents/media/<notebookId>/` — used by `MediaAttachmentStore` /
  `ImageAttachmentsView` (the new, correct path)
- `Documents/Notebooks/<notebookId>/media/` — used by the legacy
  `MediaAttachment` `@Model` path (`StorageService.mediaURL(for:)`)

Audio lives in `Documents/Notebooks/<notebookId>/audio/`. Lectures share that
directory with a `lecture_` filename prefix.

**This is the storage drift.** Three systems wrote three different layouts and
none agreed. There's no single "where do media bytes live" answer.

### 3.4 What the previous pass already fixed for image storage

[EditorViewModel.swift:147 (`commitImportedImage`)](Ink/Ink/Features/Editor/EditorViewModel.swift#L147)
was rewritten to await the file write before publishing the record (closing
the race that produced the grey box). [ImageAttachmentsView.swift's
loader](Ink/Ink/Features/Editor/Media/ImageAttachmentsView.swift#L328) was
given a retry path on `.mediaAttachmentsChanged` and a "missing file"
placeholder. Those fixes are already in main and stand independently of this
audit.

What they don't fix: the **drift root** — that the next time someone adds an
image-like surface they'll have to choose between two media directories and
two storage strategies and likely pick the wrong one again.

---

## 4. Pencil interaction subsystems

| Subsystem | API | Where state lives | Known issue |
|---|---|---|---|
| Double-tap | `UIPencilInteraction` + `UIPencilInteractionDelegate` | `EditorViewModel.activePencilDoubleTapAction` (`@Published`) | Setting is read from UserDefaults at init only — see below. Per-canvas interaction is created at canvas mount time and added to the canvas. Coordinator is the delegate; held strongly by the UIViewRepresentable's Context.coordinator (so retention is fine). |
| Squeeze (Pencil Pro) | `UIPencilInteraction.SqueezeAction` (iOS 17.5+) | [PencilSqueezeDetector.swift](Ink/Ink/Features/Editor/Tools/PencilSqueezeDetector.swift) | Has its own delegate Coordinator. Separate UIPencilInteraction instance from the double-tap one. |
| Hover (Pencil Pro proximity) | `UIHoverGestureRecognizer` (auto-installed by PKCanvasView on iPadOS 17.5+) | None — system-managed | **Bug 3.** Hover events trigger a layout pass on PKCanvasView's drawing buffer, visibly shifting rendered strokes. Previous pass added a `disableHoverRecognisers(on:)` walk; verify it actually catches the recogniser (the system installs it asynchronously after the canvas is added; the timing window may not always match `DispatchQueue.main.async`). |
| Pressure / tilt / azimuth | `PKDrawing.strokes[].path.controlPoints[].force/altitudeAngle/azimuthAngle` | Encoded in PKDrawing data | Not surfaced anywhere — PencilKit handles input attribute capture internally. |

**Concrete double-tap risk found during the read:**

[EditorViewModel.swift:647-650](Ink/Ink/Features/Editor/EditorViewModel.swift#L647-L650):
the `activePencilDoubleTapAction` is hydrated from
`UserDefaults.standard.string(forKey: "ink.pencil.doubletap")` exactly once
(in `loadPersistedState`). If the user changes the Settings → Pencil →
Double-Tap action while the editor is already mounted, the editor's value
**doesn't update** until next launch. This is a probable cause of the
"glitch" — the double-tap fires but executes the previous action.

(Separately verified that the underlying enum mismatch from earlier audits is
already fixed: settings writes the same raw values the editor reads, key is
`"ink.pencil.doubletap"` on both sides.)

**Concrete hover risk found:** the
`Self.disableHoverRecognisers(on: canvas)` call at
[ContinuousCanvasView.swift:851](Ink/Ink/Features/Editor/Canvas/ContinuousCanvasView.swift#L851)
runs once on `DispatchQueue.main.async` after the canvas is added. PKCanvasView
appears to add the hover recogniser **lazily on first hover event**, not on
mount. If that's true, the call fires before the recogniser exists and is a
no-op. A more robust fix is to install a swizzle on
`gestureRecognizers` setter or to attach a `UIGestureRecognizerDelegate` on
the canvas's superview that rejects `UIHoverGestureRecognizer`.

---

## 5. Cross-cutting findings

### 5.1 The user-frustrating loop pattern

When a user reports "image broken", the surface fix patches the symptom. The
next user report ("audio block hidden") is treated as a separate bug. They're
both symptoms of: there is no "place an annotation at normalised page (x, y)"
primitive that all media surfaces share. Each surface re-derives the
positioning math against whichever coordinate space its parent overlay
happens to provide. When the parent overlay was wired up at a different time
than the storage record, the spaces don't match and the symptom is "feature
is in the wrong place".

### 5.2 Two true root causes underneath the four bugs

1. **No shared placement contract.** Every overlay derives its own pageSize
   from a different ancestor (renderer.bounds vs base pointSize vs
   content-view GeometryReader). A single source of truth — a
   `PageCoordinateSpace` value type passed top-down — would have prevented
   the lecture/audio drift.
2. **No shared media-storage contract.** Three directories, two storage
   strategies (SwiftData entity + UserDefaults JSON record + file on disk).
   A `MediaStorage` namespace owning a single `Documents/MediaAttachments/`
   tree per type would have prevented the legacy/new directory split and
   would give one place to add the size-on-disk diagnostic the Settings
   view wants.

### 5.3 Existing things that are correct

- File-on-disk + UserDefaults metadata pattern (`MediaAttachmentRecord` /
  `LectureRecord` / `AudioAnnotation`) is the right shape. No store puts
  media bytes in UserDefaults — that "size overflow" hypothesis from the
  bug report doesn't match the code as it stands.
- `MediaAttachmentRecord.relativeFilePath` is stored relative to Documents,
  so a sandbox relocate doesn't invalidate the reference. This is good and
  should be the pattern for every media path.
- `PageExtraHeightStore` correctly lives outside the SwiftData schema; the
  V3 freeze is real and acknowledged in the code.
- Soft-delete (`deletedAt`) plus `forget(pageIds:)` reaper is consistent
  across stores.
- Per-page hosting-controller mounts for the page-scoped overlays
  (Image/Audio/Lecture) properly retain their controllers and detach on
  teardown.

### 5.4 Existing things that should be deleted, not refactored

- The `MediaAttachment` SwiftData entity — declared as
  "remains in the schema for CloudKit compatibility but is not used at
  runtime". CloudKit isn't actually wired (the iCloud sync gap from the
  earlier audit). The entity adds noise to the schema without earning it.
  Defer; not in scope for this pass but worth a follow-up.
- The legacy `Documents/Notebooks/<id>/media/` directory — used by code that
  goes through `StorageService.mediaURL(for:)` against the unused
  `MediaAttachment` entity. Also deferred.

---

## 6. Proposed scope for the structural fix pass

In priority order, what the **next** pass (after this audit is reviewed)
should change. **No code has been written yet — these are the proposals from
the spec mapped against what the audit actually found.**

### A. Single placement primitive: `PageCoordinateSpace`

Add a value type that carries the **base** page size and offers
`point(fromNormalized:)` / `normalized(fromPoint:)` conversions. Pass it
top-down from `ContinuousCanvasView` into every page-scoped overlay (Image,
Audio, Lecture). Overlays stop computing pageSize themselves.

Effective height stays a property of the renderer + scroll content size only.
**No overlay reads effective height for placement math.**

The audio pin overlay's `GeometryReader` is replaced by an explicit
`pageCoordinateSpace` parameter. The lecture overlay loses its
`CGSize(baseSize.width, effectiveHeight)` in favour of the same.

`StickyNotesOverlayView` and `TextBlockOverlayView` need a separate decision
— either give each a per-page mount like the others, or document that they
operate in content-view space and own that. The audit recommends per-page
mount for consistency, but that's a bigger change (sticky-notes today depends
on a single overlay catching the placement tap anywhere on the canvas).
Calling that out as a follow-up rather than rolling it into this pass.

### B. Single media-storage namespace: `MediaStorage`

Introduce `MediaStorage` with a single root at
`Documents/MediaAttachments/{images,audio,lectures}/`. Every new write and
every new read goes through it. The legacy `Documents/Notebooks/<id>/audio/`
path stays writable for backwards-compat reads only — a one-shot migration
on first launch moves files out.

`MediaStorage.diagnostics()` returns counts + bytes per type, surfaced in
Settings → Storage.

Drop `MediaAttachmentRecord`s whose file is missing or unloadable rather
than crashing — log a warning per dropped record.

### C. Lecture / audio default placement

Default normalised position for a new lecture or audio block:
`(0.5, 0.05)` — horizontally centred, 5% from top. Multiple blocks on the
same page stack with `0.03` normalised spacing.

Width: `0.9` normalised (90% of page width). Height auto from content (the
overlay does not constrain height).

`endLectureMode(with:)` sets the new TextBlock's normalised origin
explicitly — currently `createTextBlock(on:content:)` hardcodes `(0.06,
0.08, 0.45, 0.18)`, which is fine for most cases but means stacking is
caller-side responsibility, not callee-side.

### D. Apple Pencil hover

The current `disableHoverRecognisers(on:)` walk fires after a single
`DispatchQueue.main.async` tick, which is likely to miss recognisers added
later on first hover. Replace with one of:

- **Subview swizzle** in a `gestureRecognizers` willSet observer on a
  canvas-subclass.
- **Repeat the disable on every gesture-recogniser change** by KVO-ing
  `gestureRecognizers`.
- **Most robust**: subclass `PKCanvasView` and override
  `addGestureRecognizer(_:)` to reject `UIHoverGestureRecognizer` outright.

The third option is small, contained, and unambiguous. Recommend it.

Also: confirm with one diagnostic print that `extendLastPage` is called
exclusively from `considerAutoAddAfterStroke`. The grep already confirms one
call site, but a print at the top of `extendLastPage` during a live session
would prove no other path reaches it (e.g. via SwiftData fault-firing or a
notification listener I missed).

### E. Apple Pencil double-tap

Two changes:

- Make `activePencilDoubleTapAction` reactive to the
  `UserDefaults.didChangeNotification` for the `ink.pencil.doubletap` key.
  Today it's read once at init, so changing the setting mid-session
  silently doesn't take effect.
- Add the diagnostic print the spec asks for, behind `#if DEBUG`, in
  `pencilInteractionDidTap` to confirm delegate liveness.

### F. Out of scope for this pass (deferred)

- Migrating sticky notes / text blocks to per-page overlay mounts.
- Removing the unused `MediaAttachment` SwiftData entity.
- True iCloud sync (already a known gap from the prior audit).
- Stroke smoothing / pencil pressure setting wiring (PencilKit lacks public
  knobs — known gap).

---

## 7. Deferred to Phase 4

These are explicitly **out of scope** for the structural pass A–E. Recorded
here so they aren't lost when this audit doc is the only surviving artefact
of this period.

1. **Migrate `StickyNotesOverlayView` to per-page mounts.** Currently uses
   the full content view's `GeometryReader` size as its "page" coordinate
   space — different normalised contract from every other store. Works only
   by accident on single-page notebooks; multi-page positioning likely
   wrong. Same per-page-renderer mount the Image / Audio / Lecture overlays
   use applies cleanly.
2. **Migrate `TextBlockOverlayView` to per-page mounts.** Currently floats
   with the active page in `overlayLayer`. Works but is structurally
   inconsistent — the only floating overlay left after sticky notes
   migrates.
3. **Delete the unused `MediaAttachment` SwiftData `@Model` entity.** The
   "for CloudKit compatibility" rationale is invalid (CloudKit isn't
   wired). Once we confirm no production data references it (a launch-time
   `fetchCount` check would prove it), drop it from the V3 schema. Schema
   bump risk: SwiftData refuses duplicate version checksums; removing the
   entity may require a fresh V4. Defer until iCloud is decided.
4. **Wire CloudKit sync for unified `MediaStorage` records.** Today the
   metadata records are UserDefaults JSON which means they don't sync.
   Decide: either move records to SwiftData (synced) or accept media is
   device-local only and document it. Audio bytes already follow whatever
   the iCloud-Drive directory toggle produces; the records don't.
5. **Unified `EditorStateMachine`.** Cover `selectedTool`, `selectedEntity`
   (image/text/sticky/audio), and `activeMode` (lecture, audio recording,
   etc.) under one source of truth. Currently spread across multiple
   ViewModels and Combine sinks; transitions like "stop lecture mid-flight
   when the user opens the customise panel" rely on each side observing
   the other rather than a single state machine arbitrating.
6. **Unified modal presenter at `RootView` level.** All sheets / popovers /
   `fullScreenCover`s route through one presenter. Eliminates the
   `.sheet`-inside-`.fullScreenCover` collapse class of bug permanently.
   Affects ImageImportPicker, ExportOptionsView, RecentExportsView,
   SettingsView, NewNotebookSheet, AskMyNotesSheet, all popover usages.
   Significant refactor — flag for the next architectural pass after this
   subsystem stabilises.
7. **Trim `MediaStorage.migrateExistingFilesIfNeeded()` body.** Phase 3
   landed a defensive 3-store migration scan (image / audio / lecture).
   With no shipping data and the no-backwards-compat green light, the
   migration is dead code on every sandbox. Replace the body with
   `ensureDirectoriesExist()` + flag write; delete the per-store
   `migrateImages` / `migrateAudioAnnotations` / `migrateLectureRecords`
   helpers. ~150 lines drop. The `migrationFlagKey` UserDefault entry
   can stay (it's a single boolean) or be removed — either is fine.
8. **Collapse `StorageService.audioURL(for:)` legacy fallback.** Phase 3
   added a modern-path-first / legacy-path-fallback resolver to support
   unmigrated audio files. With no shipping data, replace with a direct
   `MediaStorage.url(for: .audio, id: annotation.id)` return. Delete the
   sibling `legacyAudioURL(for:)` and `allActiveAudioAnnotations()`
   helpers — they exist only for the migration sweep removed in §7.7.

These items are also reflected in `Documentation/MEDIA_SUBSYSTEM_AUDIT.md`'s
own commit history if anyone needs to see when they were added.

---

## 8. Verification checklist (will run after the structural fixes land)

These are the spec's checklist items; included here so the post-fix pass has
a single source of truth.

- [ ] Audit document exists at `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` ← this file
- [ ] Insert image → image renders correctly with actual photo content (not grey box)
- [ ] Close and reopen notebook → image still renders
- [ ] Draw strokes near image → image does NOT shift position
- [ ] Start lecture recording → lecture card appears VISIBLE inside page bounds
- [ ] Start quick audio → audio card appears VISIBLE inside page bounds
- [ ] Tap audio/lecture card → interaction works (transcript shows / playback works)
- [ ] Hover Apple Pencil over canvas without touching → nothing moves
- [ ] Double-tap Apple Pencil → console prints `[Pencil] double-tap fired`, action executes
- [ ] Existing image records (if any) either render correctly or are cleanly dropped (no crash)
- [ ] All overlay layers use `PageCoordinateSpace` with **base** size, never effective size

---

## 9. Read-the-room note

The frustration the user described in the prompt is the right read of this
codebase. Each of the four bugs has a different proximate cause (storage
race, position centring, system gesture recogniser, UserDefaults reactivity
gap), but **all four became hard to find because the architecture doesn't
make them easy to reason about**. The structural fixes proposed in §6 are
small in code volume (one value type, one namespace, two delegate
adjustments) but worth the time because they remove the conditions that
generate this class of bug.

Recommend reviewing §1, §2, and §6 in particular, then green-lighting the
structural pass. Will not start refactoring until you do.

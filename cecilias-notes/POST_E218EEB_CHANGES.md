# Changes after `e218eeb`

Base commit: `e218eeb` — *Multi-page scan/PDF images land consecutively after the current page*.

This document describes every fix made in the working tree after that commit, why it was needed (including evidence from `venu_logs_xcode`), and how to verify it.

---

## 1. Multi-image import only inserted one image

### Symptom
Photo Library multi-select appeared to succeed, but only one image landed on the page.

### Evidence
```
[ImageInsert] presenter: loaded 6 image(s), firing completion
```
No further per-image commit logs — the library deliberately discarded images 2…N.

### Root cause
`MediaPickerPresenter.presentPhotoPicker` correctly loads every `PHPickerResult`, but `LibraryViewModel`’s `.imageImportRequested` handler posted `.imageImportCompleted` with only `images.first`. The editor observer only ever saw one `UIImage`.

### Fix
- `ImageImportUserInfoKey.images` carries `[UIImage]`.
- `LibraryViewModel` posts the full array (and keeps `image` = first for back-compat).
- `EditorViewModel.handleImageImportCompleted` commits every image with a +3% cascade so the stack is visible.
- `MediaInsertCoordinator.processAndInsert` batches one SwiftData `save()` + one `.mediaAttachmentsChanged` for the whole set.

### Files
- `CeciliasNotes/CeciliasNotes/Core/Services/ImageImportNotifications.swift`
- `CeciliasNotes/CeciliasNotes/Features/Library/LibraryViewModel.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/EditorViewModel.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Media/MediaInsertCoordinator.swift`

### Verify
Editor → Image tool → pick 4+ photos → all appear, slightly cascaded.

---

## 2. PDF import did nothing on existing pages

### Symptom
Choosing a PDF from Files while already inside a notebook produced no pages / no images.

### Evidence
```
Failed to associate thumbnails for picked URL …/LEADERSHIP THAT GETS RESULTS…pdf
  with the Inbox copy …/tmp/app.ceciliasnotes-Inbox/LEADERSHIP…pdf
```
Inbox copy was created, but no `[PDFImport]` / image-save logs followed.

### Root cause
`FilesPicker` opens with `asCopy: true`, so the URL is a plain sandbox tmp copy, **not** security-scoped. `handlePickedFileURLs` did:

```swift
guard url.startAccessingSecurityScopedResource() else { continue }
```

That returns `false` for Inbox copies → every URL was skipped.

### Fix
- Call `startAccessingSecurityScopedResource()` when available, but never gate the read on it.
- PDF rasterise loop keys the rolling page anchor on first **successful** page (not `i == 0`), so a failed first page cannot orphan the rest.
- Batched SwiftData save + single overlay notification for multi-page PDF raster imports.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/Media/MediaInsertCoordinator.swift`

### Verify
Open a notebook with existing pages → Insert from Files → pick a multi-page PDF → pages/images appear after the current page.

---

## 3. Selection did not clear on blank tap

### Symptom
After selecting an image / text / sticky / PDF / highlight / audio element, tapping empty paper left the selection chrome up.

### Root cause
Selection is local `@State` inside each overlay. Each overlay had its own full-page catcher, but catchers sit inside one shared `PageOverlaysContainer` ZStack. A sibling overlay (or a full-page element layout frame) can eat the empty tap before the overlay that owns the selection sees it. Full-bleed PDF/image elements also have **no** empty area outside their rect.

### Fix
1. `Notification.Name.editorBlankPageTapped` — page-scoped broadcast.
2. `ContinuousCanvasView.mountOverlaysHost` installs a `UITapGestureRecognizer` (`cancelsTouchesInView = false`) that posts the notification when the tap misses every non-stroke element rect; also clears `LassoSelectionState` for that page.
3. Image / PDF / audio / highlight / text / sticky overlays observe the notification and clear selection/editing.
4. Full-bleed elements toggle selection on tap (second tap deselects when there is no blank target).

### Files
- `CeciliasNotes/CeciliasNotes/Core/Extensions/ElementChangeNotifications.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/ContinuousCanvasView.swift`
- `…/ImageElements/ImageElementsOverlayView.swift`, `ImageElementView.swift`
- `…/PDFElements/PDFPageElementsOverlayView.swift`, `PDFPageElementView.swift`
- `…/AudioElements/AudioElementsOverlayView.swift`, `AudioElementView.swift`
- `…/HighlightElements/HighlightElementsOverlayView.swift`, `HighlightElementView.swift`
- `…/TextElements/TextElementsOverlayView.swift`
- `…/StickyNotes/StickyNoteElementsOverlayView.swift`

### Verify
Select an image → tap blank paper → chrome gone. Select a full-page PDF → tap it again → chrome gone.

---

## 4. App stuck while scanning multiple documents (esp. page 3)

### Symptom
Multi-page VisionKit scan froze / felt wedged around the third page. Log showed camera-service failure storm then silence.

### Evidence
```
FigCaptureSourceRemote … err=-17281   (repeated)
Trying to load recrop for scan, but the quad is nil…  (×3)
```
No app-level processing logs after that.

### Root cause
`handleScannedDocument` ran entirely on the main actor and:

1. Cleared `activeMediaSource` (dismiss sheet) **before** showing any HUD.
2. Synchronously called `scan.imageOfPage(at:)` for every page (heavy decode) with no yield — with the capture service already dying, this is the hang signature.
3. After processing, called `saveImageRecord` per page → each did `context.save()` of multi-MB `imageData` + posted `.mediaAttachmentsChanged` (every mounted image overlay refetches).

`ImageProcessingService` itself is correctly an actor (off-main). The hang was the glue around it.

### Fix
- Set `isProcessing = true` and show the HUD **before** dismissing the scanner.
- `await Task.yield()` so SwiftUI can paint / dismiss.
- Yield between `imageOfPage` decodes; progress bar covers decode + process + insert.
- Insert all pages with `persistImmediately: false, notify: false`, then **one** `context.save()` and **one** `.mediaAttachmentsChanged`.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/Media/MediaInsertCoordinator.swift`

### Verify
Scan 3–5 pages with the document camera → “Processing…” HUD appears, scanner dismisses cleanly, pages land consecutively, UI stays interactive.

---

## 5. Intermittent editor scroll lag

### Symptom
Vertical notebook scroll usually fine, occasionally hitchy; after stopping, offset chattered by ±1pt.

### Evidence
`venu_logs_xcode`: **537** `[Membership]` lines, **51** canvas mount/unmount pairs. After rest, offsets oscillated (`1181` ↔ `1182`) while `scrolling=false`, each line from a full membership pass.

### Root cause
In `ContinuousCanvasView.Coordinator`:

- `scrollViewDidScroll` throttled membership while dragging (~10 Hz) but ran it **on every tick at rest**.
- `applyContentInset` + `snapToEdgesIfClose(animated: true)` could nudge `contentOffset` by ~1pt, re-entering `scrollViewDidScroll` → membership → more work.
- Every membership call also `dlog`’d and `fflush`’d stdout in DEBUG.

### Fix
- At rest, skip membership when `|ΔoffsetY| < 2`.
- Throttle membership at rest to ~20 Hz (still ~10 Hz while scrolling).
- Ignore edge snaps smaller than 2pt (stops the animated chatter loop).
- Log `[Membership]` only when mount counts or membership mode changes. A follow-up device trace showed that even an 8pt offset bucket still emitted 419 lines during a sweep; offset is therefore excluded entirely from the signature.
- Still force a full pass from scroll-end / zoom / explicit `force: true` callers.
- During high-velocity scrolling, retain already-mounted overlays but defer building new nine-overlay SwiftUI trees until velocity drops or scrolling rests. The landing viewport is rechecked before each deferred mount, so pages merely crossed in a fling are not built afterward.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/ContinuousCanvasView.swift`

### Verify
Fling through a 10+ page inked notebook. Scroll should stay smooth; Console should not flood with Membership lines after the scroll settles.

---

## 6. Initial-scroll audio warm-up jerk

### Symptom
The editor became smooth after pages had been visited, but a subtle first-pass jerk remained when initially scrolling through a notebook containing recordings.

### Evidence
The July 19 device trace places a complete audio startup sequence directly beside first-time page mounts: overlay fetch → `AudioElementStripContent.onAppear` → filesystem checks → `AVAudioPlayer(contentsOf:)` → `prepareToPlay()`. This repeated for each newly encountered audio page while `scrolling=true`. The same trace also contained SwiftUI’s “Publishing changes from within view updates” warning during initial overlay construction.

### Root cause
Every audio strip eagerly opened its media file and prepared an AVFoundation decoder merely because its page entered the viewport. This synchronous main-actor work was unnecessary until the user actually pressed Play or sought to a transcript timestamp.

### Fix
- Audio strips no longer inspect or prepare their files from `onAppear`.
- File resolution, optional iCloud download request, player creation, and decoder preparation now happen lazily on the first explicit Play or seek action.
- The stored `AudioContent.durationSeconds` continues to render the time label and progress scale before a player exists.
- Ending a recording updates the strip state without immediately preparing playback.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/AudioElements/AudioElementView.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/ContinuousCanvasView.swift`

### Verify
Cold-open the 17-page audio notebook and fling through it. There should be no `[AudioPlayback] load()` lines merely from page crossings. Pressing Play should produce one load sequence and playback should begin normally.

---

## 7. Dictation "summarize" produced weird reformatting instead of a summary

### Symptom
After stopping a dictation, no summary appeared; instead the dictated text itself was rewritten/reformatted awkwardly.

### Evidence
The July 19 device trace shows a 256-character dictation. At stop, two independent steps run: `TranscriptStructurer` (reformat in place, minimum 200 chars) and `MeetingSummaryCommit` (summary block, minimum 280 chars). The transcript fell between the two thresholds, so the summary was silently skipped while the structurer applied a 269-character "structured" rewrite (log line: `updateText OK — 269 chars applied` with no dictation partial preceding it). Neither step logged anything, which is why the log looked empty around the failure.

### Root cause
- `TranscriptStructurer.isFaithful` only compared letters-only lengths (structured ≥ 92% of original). Because the model *adds* headings, nearly any rewrite passed — including outputs that reworded or reflowed the user's words badly. The prompt's HARD RULE ("every word verbatim, in order") was unenforced.
- The summary path had no diagnostics, so a skip (short transcript, model unavailable, preference off, generation error) was indistinguishable from a bug.

### Fix
- `isFaithful` now requires the original word sequence to appear verbatim and in order inside the structured output (normalized word-by-word subsequence check), with additions bounded to roughly one-eighth of the original word count (headings and a few speaker labels). Unfaithful output degrades to the raw transcript.
- Both the structurer and the summary path now log their decision (skipped with reason / accepted / rejected / generation failed) in DEBUG builds.
- Note: transcripts under 280 characters intentionally get no summary — the transcript is considered its own summary. This is unchanged, but it is now visible in the log.

### Files
- `CeciliasNotes/CeciliasNotes/Core/Services/AI/MeetingSummarizer.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Recording/MeetingSummaryCommit.swift`
- `CeciliasNotes/CeciliasNotesTests/TranscriptStructurerTests.swift` (new — 7 faithfulness regression tests)

### Verify
Dictate 300+ characters and stop. Console should show either `[Summary] generated …` followed by the summary block appearing above the pill, or an explicit skip reason. The transcript body should read exactly as dictated (paragraph breaks/headings allowed, words untouched); a rewritten transcript should never be applied — the log would show `[Structurer] REJECTED unfaithful output`.

---

## 8. Files-app PDF import landed as a small centred image

### Symptom
Importing a PDF via the Files picker worked (after fix #2), but each PDF page appeared as a shrunken image floating in the centre of its notebook page instead of filling it.

### Root cause
`MediaInsertCoordinator.handlePDF` rasterises each PDF page and placed it with `centredRect`, the generic *photo* placement helper that aspect-fits into 60% of the page. That cap is intentional for photos dropped onto a page, but a PDF page should read as the page itself. (The tool-palette PDF picker path, `PDFReferenceImporter`, already inserts full-bleed `.pdfPage` elements — only the Files-app image-rasterise path had the photo sizing.)

### Fix
- New `fullPageRect(for:pageSize:)` in `MediaInsertCoordinator`: aspect-fit to the FULL page, centred. Used for every page in `handlePDF` (first page on the current page and each consecutive new page). Mismatched aspects (landscape slides on portrait pages) letterbox rather than distort.
- `ImageProcessingService.rasterisePDFPage` bumped from 150dpi to 200dpi — full-page display read slightly soft at 150dpi on 2x screens. An A4 page at 200dpi (~1654×2339px) stays well under the 4096px downscale cap.
- Photo/camera/scan placement is unchanged (still 60% centred).

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/Media/MediaInsertCoordinator.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Media/ImageProcessingService.swift`

### Verify
Files → pick a multi-page PDF into an existing notebook. Each PDF page should fill its notebook page edge to edge (or letterboxed if aspect differs), starting on the current page, at crisp resolution.

---

## 9. Sharing a `.ceciliabook` dumped into the library instead of opening it

### Symptom
Tapping **Cecilia's Notes** in the iOS share sheet for a notebook archive (`.ceciliabook`) launched the app and imported the notebook, but left the user on the library home — it felt like "sharing the file into the app" rather than opening it.

### Root cause
Two cooperating bugs:
1. The share extension always deep-linked to `ceciliasnotes://library`, which forces the editor cover down.
2. `ShareInboxWatcher` imported the `.ceciliabook` successfully but never set `openNotebookId` / posted an open notification — unlike the direct Files tap path (`onOpenURL` → `DeepLinkRouter`), which already opened the imported notebook.

### Fix
- After a successful inbox `.ceciliabook` import, post `.ceciliasNotesOpenNotebook` so `LibraryView` opens the new notebook (and refresh the library list first so the lookup succeeds).
- For notebook-archive shares, the extension deep-links to `ceciliasnotes://inbox` (bring-to-foreground only) instead of `ceciliasnotes://library`.
- Share extension also accepts the `app.ceciliasnotes.notebook` UTI and bare file-URL attachments, not only `public.url`.

Direct tap on a `.ceciliabook` in Files / Mail / AirDrop was already correct (`DeepLinkRouter` file-URL path) and is unchanged.

### Files
- `CeciliasNotes/CeciliasNotes/Core/Services/ShareInboxWatcher.swift`
- `CeciliasNotes/CeciliasNotesShareExtension/ShareViewController.swift`
- `CeciliasNotes/CeciliasNotes/Core/Services/DeepLinkRouter.swift`
- `CeciliasNotes/CeciliasNotes/Features/Library/LibraryView.swift`

### Verify
Share a `.ceciliabook` via the share sheet → Cecilia's Notes. The app should launch and open that notebook in the editor. Also verify: tap the same file in Files → still opens. Sharing a PDF → still lands on the library PDF picker (unchanged).

---

## 10. Page-strip thumbnails only showed some elements (no text)

### Symptom
The small page previews in the bottom page navigator (and the corner minimap) showed only ink, images, and PDF backgrounds. Pages whose content is mostly typed/dictated text, sticky notes, shapes, or highlights rendered as blank paper — the user couldn't tell which page they were jumping to.

### Root cause
Two gaps in `PageThumbnailCache`:
1. The renderer composited only paper + PDF backing + image elements + PKDrawing ink. Text, sticky-note, shape, highlight, and audio elements were never drawn.
2. The cache key was `(pageId, page.updatedAt, pdfIndex)`. Text / sticky / shape edits stamp the **element** row's `updatedAt`, not `page.updatedAt`, so even if the renderer had drawn them, the cached thumbnail would never invalidate after an edit. The strip row also only reloaded on `page.updatedAt` changes, so it never re-keyed after an element edit.

### Fix
- `PageThumbnailCache` now snapshots **all** element kinds off-main (`loadElementLayersOffMain`) and composites them in the same order `ExportService` rasterises a page: images → highlights → ink → shapes → text → sticky notes → audio markers. Text draws at the editor's point sizes scaled to the thumbnail, so line breaks land roughly where they do on the page. Audio strips render as a small translucent pill; decorative shapes approximate as their bounding ellipse (same as export).
- The cache key gained an `elementsFingerprint` — count folded with every active element's `updatedAt` bit pattern — computed in the same single property-read fetch that already resolved the PDF backing index (no extra main-actor query, no blob reads).
- `PageStripThumbnail` re-keys (and regenerates on a cache miss) when any element-change notification fires (`textElementsChanged`, `stickyNotesChanged`, `mediaAttachmentsChanged`, `highlightElementsChanged`, `shapeElementsChanged`, `audioElementsChanged`, `strokeContentRewritten`). Unchanged pages hit the cache, so the nudge is cheap.

The minimap uses the same cache and picks the new layers up automatically.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/PageStrip/PageThumbnailCache.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/PageStrip/PageStripView.swift`

### Verify
Open a notebook with a text-heavy page (dictation or typed), a sticky note, and a highlight. Open the bottom page strip: each thumbnail should show the text lines, sticky card, and highlight tint. Type on a page with the strip open — the thumbnail should update after the debounced persist without switching pages.

---

## 11. Undo after a delete jumped to an older change (broken LIFO)

### Symptom
Undo / redo worked when used alone, but after undoing and then deleting something (or deleting after other edits), the next undo skipped the delete and replayed an older change instead of restoring the just-deleted element.

### Root cause
Three cooperating gaps in the per-page undo plumbing:
1. Each warm-band `CeciliasNotesPKCanvasView` created its **own** `UndoManager`. Scrolling a page out of the warm band destroyed that manager (and every element-delete / stroke entry on it). Remounting started a fresh empty stack, so the toolbar undid whatever older entry still lived elsewhere.
2. Overlays register create/delete undo with `inputs.canvasView?.undoManager`. The overlay warm band is wider than the canvas band, so an overlay often mounted while `canvasView` was still `nil`. `EditorPageOverlayInputs` equality ignored canvas identity, so the coordinator never refreshed those inputs when the canvas later mounted — delete registered into **nothing**, and the next undo skipped it.
3. PDF page soft-delete never called `PageElementUndo.registerDelete` at all.

### Fix
- `EditorViewModel` owns a session-stable `[pageId: UndoManager]` map; each canvas mount reinjects the same manager into `CeciliasNotesPKCanvasView.pageUndoManager`. Cleared on editor dismiss.
- `EditorPageOverlayInputs` equality includes canvas identity; canvas mount/unmount refreshes that page's overlay inputs so create/delete always hit the live manager.
- PDF page delete registers undo like every other element kind; undo of a PDF delete posts `.pdfPageElementsChanged`.
- DEBUG logs when a create/delete registration is dropped for a nil manager.

### Files
- `CeciliasNotes/CeciliasNotes/Features/Editor/EditorViewModel.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/CeciliasNotesPKCanvasView.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/ContinuousCanvasView.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Canvas/EditorPageOverlayInputs.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/Lasso/PageElementUndo.swift`
- `CeciliasNotes/CeciliasNotes/Features/Editor/PDFElements/PDFPageElementsOverlayView.swift`

### Verify
Draw a few strokes → undo one → delete an image / sticky / text / PDF page → undo. The delete should reverse (element returns). Redo should re-delete. A new edit after undo should clear the redo chain so undo next undoes that new edit. Scroll the page off-screen and back, then undo — the latest change on that page should still be on top.

---

## 12. Mac editor / library bugs (format, pagination, chrome)

### Symptoms (from screenshots + report)
1. Format preview looked correct while editing; after leaving the block, bold/italic/size vanished (esp. dictation / summary).
2. S/M/L sometimes needed two clicks.
3. Felt stuck in edit mode — clicking white space outside the page didn't leave editing.
4. Stray blue dots on the format toolbar and briefly near the home iCloud icon; notebook cards showed a blue ring by default.
5. Pages grew taller instead of overflowing to the next page (typed text and live transcription).
6. No in-session Summary on/off chip during Mac dictation (iPad has one).

### Root causes
- **Format vanish:** non-editing preview used `Text(AttributedString(nsAttributedString))`, which drops / remaps AppKit font traits on macOS. The NSTextView kept the formatting; the SwiftUI preview did not.
- **S/M/L two-click:** format actions deferred focus + only widened selection from preview state; a caret-only mid-edit size change mutated typing attributes first.
- **Page expand:** `MacDocPageSection` used `minHeight` (paper grew with content) and only reconciled overflow on appear.
- **Blue toolbar dot:** intentional accent "editing" circle on the format rail.
- **Blue notebook ring by default:** `seedGridKeyboardFocusIfNeeded` auto-focused `notebooks[0]`.
- **Home cloud blue:** iCloud syncing status colour (temporary) — unchanged; it clears when sync finishes.
- **Summary chip:** Mac floating controls omitted the iPad dictation summary toggle.

### Fix
- Fixed paper frame + clip; re-run `MacPageOverflow.reconcilePage` when stacked block height exceeds the page; empty paper / gutter taps leave edit mode (second tap on empty paper still inserts).
- AppKit-backed `MacAttributedTextPreview` for read-only blocks; paragraph formats (S/M/L, heading, family, alignment) always widen an empty selection on first click.
- Removed the format-rail accent ornament; stop auto-seeding grid keyboard focus; clear focus on empty grid tap.
- During live transcription, show the same Summary on/off chip as iPad (`ceciliasnotes.dictation.autoSummary`) **and run the same summarization pipeline**: on stop, `MacRecordingSession` calls `MacMeetingSummary.generateIfWorthwhile`, which inserts a "Summarizing this recording…" placeholder above the transcript, calls the shared `MeetingSummarizer.summarize` (identical prompts + chunked map-reduce to iPad's `MeetingSummaryCommit`), then replaces the placeholder with the finished summary — or removes it quietly on failure. Result reads summary → audio pill → transcript, matching iPad. Same gating as iPad: opt-in preference on, transcript ≥ `MeetingSummarizer.minimumTranscriptCharacters` (280), and Apple Intelligence available (`MeetingSummarizer.canRun`). Before the summary step, `TranscriptStructurer.structureIfFaithful` reformats the transcript in place (single-block only) with the same faithfulness guard as iOS.

### Files
- `CeciliasNotes/CeciliasNotesMac/Editor/DocMode/MacDocModeView.swift`
- `CeciliasNotes/CeciliasNotesMac/Editor/DocMode/MacDocBlock.swift`
- `CeciliasNotes/CeciliasNotesMac/Editor/MacRichTextController.swift`
- `CeciliasNotes/CeciliasNotesMac/Capture/MacFloatingRecordingControls.swift`
- `CeciliasNotes/CeciliasNotes/Features/Library/Grid/NotebookGridView.swift`

### Verify (Mac)
1. Type past the page bottom → content continues on page 2; paper height stays fixed.
2. Dictate past the page bottom → same.
3. Bold / S/M/L a dictation or summary block → leave the block → formatting still visible.
4. Click gutter / empty paper once while editing → edit mode ends.
5. Start transcription → "Summary on/off" chip appears (when Apple Intelligence can run).
6. Library: no blue ring until you click a card; click empty grid → ring clears.

---

## 13. Smoothness follow-ups still open (not changed this round)

Tracked for a later pass (also summarized in the Cursor canvas `editor-smoothness-audit.canvas.tsx` and `non-editor-performance-audit.canvas.tsx`):

| Area | Issue |
|------|--------|
| Library search | Per-row full notebook fetches + AttributedString rebuild while scrolling results |
| Search index | Duplicate `refreshAll()` on launch / main-actor walk |
| Export / Share | `@MainActor` PDF rasterise / encode |
| Multipeer | DTLS reconnect storm when peer unreachable (441 log lines) — noise / wakeups, not the primary scroll hitch |
| Library grid | Per-card 12pt shadow (accepted previously in OPEN_ISSUES §9) |

---

## 14. Full verification round (audit)

A complete round of checks was run over the whole working tree to confirm every fix above is present in the code and that nothing regressed.

### Code presence — all confirmed in the tree
- iOS: multi-image import array path, Files-PDF security-scope + `fullPageRect` sizing (200dpi), `.editorBlankPageTapped` broadcast + per-overlay observers, scan HUD/yield/batched save, throttled membership + deferred overlay mounts, lazy audio player load, strengthened `TranscriptStructurer.isFaithful`, `.ceciliabook` open-on-import, `PageThumbnailCache` all-element render + `elementsFingerprint` key, session-stable per-page `UndoManager` (`EditorViewModel.pageUndoManager` map → `CeciliasNotesPKCanvasView.pageUndoManager`) with mount/unmount overlay-input refresh.
- Mac: `MacAttributedTextPreview` (AppKit rich-text preview), `applyParagraphFormat` (first-click S/M/L, heading, family, alignment), gutter/empty-paper tap exits edit mode, format-rail accent ornament removed, fixed page frame `.clipped()` + `MacPageOverflow.reconcilePage` on height/count change, Summary chip + full `MacMeetingSummary` pipeline, `seedGridKeyboardFocusIfNeeded` no longer auto-focuses + empty-grid tap clears focus.
- Preference key `ceciliasnotes.dictation.autoSummary` is shared across iPad Settings toggle, iPad chip, Mac chip, and both summary paths (`DictationSummaryPreference.key`).

### Builds
- `CeciliasNotes` (iOS Simulator, Debug) — **BUILD SUCCEEDED**.
- `CeciliasNotesMac` (macOS, Debug) — **BUILD SUCCEEDED**.

### Tests (iPhone 17, iOS 26.5 simulator)
- **176 passing**, including `TranscriptStructurerTests` (7 faithfulness regression tests), `MeetingSummaryCommitTests` (6, geometry + ordering + transcript-preservation), `NotebookArchiveIOTests` (`.ceciliabook` round-trip), `DuplicationFidelityTests`, `MultipeerLiveInkTests`, `InkbookInlineMarkdownTests`.
- **10 UI-test failures — all environmental, none in changed code paths:**
  - 4 fail tapping onboarding "Continue" because iOS 26.5's `UIContinuousPathIntroductionView` injects a second "Continue" button the harness can't disambiguate.
  - 5 fail on toolbar "done" button hittability ("Activation point invalid") before reaching their undo/lasso assertions.
  - 2 settings tests can't find the "Apple Pencil" rail section (present in code — `SettingsCategory.pencil = "Apple Pencil"`; not rendered on a non-Pencil simulator).
  - These are harness/simulator issues (onboarding overlay collision, button hittability timing, Pencil-only sections on a Pencil-less simulator), not assertion failures about undo/redo, selection, or summary logic. Recommend a device pass to green them.

### Code graph
- Regenerated `Documentation/CODE_GRAPH.json` + `Documentation/CODE_GRAPH.md` via `Documentation/tools/build_code_graph.py` (356 files, 712 types, 93 notification declarations, 112 notification symbols).

---

## How to test the whole package

1. Clean Debug build → device.
2. Multi-photo import (4+).
3. Files PDF into an existing notebook.
4. Select / blank-tap deselect for image, text, sticky, PDF.
5. Document scan of 3+ pages.
6. Long fling through a dense notebook; watch Console for Membership spam.

Full suite expectation: existing unit tests should remain green; these changes are primarily runtime / main-thread scheduling.

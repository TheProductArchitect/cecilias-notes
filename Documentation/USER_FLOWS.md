# User Flows — Every Device, Every Path

_iPad is the source of truth. iPhone adapts iPad's flows to a compact form factor and drops what needs a Pencil. Mac adapts iPad's flows to a windowed, keyboard-first, indirect-input model — and benchmarks against Granola for the "capture on the desk" surfaces._

For the machine-queryable version see [`USER_FLOWS.yaml`](USER_FLOWS.yaml). For structural code map see [`CODE_GRAPH.md`](CODE_GRAPH.md). For a verification-and-fix run see [`prompts/verify_user_flows.md`](prompts/verify_user_flows.md).

**Status legend** — used per device per flow:
- `implemented` — shipped and verified
- `partial` — path exists but degraded or missing polish
- `stub` — placeholder ("iPad-only" empty state) that should become a real flow
- `missing` — recommended, not yet built
- `n/a` — intentionally not offered on this device (with reason)

**Device shorthand** — `iPad`, `iPhone`, `Mac`. iPad is authoritative; missing = "should exist" unless the device column reads `n/a`.

**UX principle for adaptation** — same job, native gestures. Sheets on iPad become windows on Mac. Long-press on iPad becomes right-click on Mac. Drawer sidebar on iPhone becomes inline sidebar on iPad/Mac. Nothing about the editorial visual language changes across devices.

---

## Table of contents

1. [First-run & onboarding](#1-first-run--onboarding)
2. [Library — navigation](#2-library--navigation)
3. [Library — notebooks](#3-library--notebooks)
4. [Library — subjects](#4-library--subjects)
5. [Library — quizzes](#5-library--quizzes)
6. [Library — trash](#6-library--trash)
7. [Library — search & tags](#7-library--search--tags)
8. [Library — Ask My Notes (AI)](#8-library--ask-my-notes-ai)
9. [Editor — opening & pages](#9-editor--opening--pages)
10. [Editor — strokes (Apple Pencil)](#10-editor--strokes-apple-pencil)
11. [Editor — text & sticky notes](#11-editor--text--sticky-notes)
12. [Editor — images & media](#12-editor--images--media)
13. [Editor — PDF import & annotation](#13-editor--pdf-import--annotation)
14. [Editor — audio, dictation, lecture](#14-editor--audio-dictation-lecture)
15. [Editor — highlights, shapes, annotations](#15-editor--highlights-shapes-annotations)
16. [Editor — AI (summarize, ask, agent)](#16-editor--ai-summarize-ask-agent)
17. [Editor — customisation & cover](#17-editor--customisation--cover)
18. [Editor — export & share](#18-editor--export--share)
19. [Settings](#19-settings)
20. [Sync — CloudKit & Multipeer](#20-sync--cloudkit--multipeer)
21. [Handoff & continuity](#21-handoff--continuity)
22. [Widgets & complications](#22-widgets--complications)
23. [System integrations](#23-system-integrations)
24. [Accessibility & input](#24-accessibility--input)
25. [Mac-only flows benchmarked to Granola](#25-mac-only-flows-benchmarked-to-granola)
26. [Recommended missing flows](#26-recommended-missing-flows)

---

## 1. First-run & onboarding

### 1.1 Splash → onboarding hand-off
- **iPad** `implemented` — `SplashView` → `OnboardingView`. Editorial fade-in wordmark.
- **iPhone** `implemented` — same, compact spacing.
- **Mac** `implemented` — `SplashView` skipped (window opens straight into onboarding sheet).

### 1.2 Name entry with live wordmark preview
- **iPad** `implemented` — `OnboardingView` step 1: 96pt `BrandWordmark` recomposes on every keystroke; `validateName` gate (letters only, first word wins). Files: [`Features/Onboarding/OnboardingView.swift`](../CeciliasNotes/CeciliasNotes/Features/Onboarding/), [`PersonalIdentity.swift`](../CeciliasNotes/CeciliasNotes/Features/Onboarding/PersonalIdentity.swift).
- **iPhone** `implemented` — same flow, tighter type scale.
- **Mac** `implemented` — `MacOnboardingView` step `.name` mirrors the iPad. **UX note:** field is `FocusState`-focused on open so the user can type immediately without clicking. `Return` advances.

### 1.3 iCloud sign-in reminder
- **iPad** `implemented` — copy step in onboarding.
- **iPhone** `implemented` — same.
- **Mac** `implemented` — step `.sync` in `MacOnboardingView`.

### 1.4 Handwriting-only-on-iPad expectation
- **iPad** `n/a` — no need to explain.
- **iPhone** `partial` — should be one line in onboarding: "Handwriting stays on iPad; everything else works here."
- **Mac** `implemented` — step `.done` in `MacOnboardingView`.

### 1.5 App icon picker (personalisation extension)
- **iPad** `implemented` — `IconPreviewView` in Settings.
- **iPhone** `implemented` — same.
- **Mac** `n/a` — macOS doesn't support `setAlternateIconName`; icon is fixed. Do not show the picker.

### 1.6 Re-run onboarding from Settings
- **iPad** `implemented` — Settings → Appearance → "Show onboarding again" resets `PersonalIdentity.onboardingCompletedKey`.
- **iPhone** `implemented`.
- **Mac** `partial` — hook exists (`MacSettingsView`), verify it clears the same key.

---

## 2. Library — navigation

### 2.1 Open library on launch
- **iPad** `implemented` — `RootView` → `LibraryView`.
- **iPhone** `implemented` — same view; sidebar collapses to drawer.
- **Mac** `implemented` — `MacRootView` full-plane composition.

### 2.2 Show / hide sidebar
- **iPad** `implemented` — sidebar is permanently inline at 240pt.
- **iPhone** `implemented` — drawer overlay; toggle via masthead icon.
- **Mac** `implemented` — inline 240pt. **UX gap:** no `⌘⌥S` shortcut to collapse. Recommended: `⌘⌥S` toggles sidebar visibility (matches Notes.app, Xcode, Craft).

### 2.3 Switch selected subject
- **iPad** `implemented` — tap sidebar row, 2pt selection rule slides.
- **iPhone** `implemented` — tap row, drawer auto-closes.
- **Mac** `implemented` — single-click row; arrow keys `↑↓` should also navigate. **UX gap:** verify keyboard navigation of sidebar; Granola uses `⌘1`–`⌘9` for quick jumps to top folders.

### 2.4 "All subjects" overview
- **iPad** `implemented` — `AllSubjectsView`, grid of subject cards.
- **iPhone** `implemented`.
- **Mac** `stub` — `MacEmptyState` says "Use your iPad to bulk-edit subjects." **Recommendation:** upgrade to full grid on Mac; there is no reason this needs a Pencil.

### 2.5 "All quizzes" overview
- **iPad** `implemented` — `AllQuizzesView`.
- **iPhone** `implemented`.
- **Mac** `stub` — same treatment as above; **recommend implementing** (read-only playback is trivial on Mac).

### 2.6 Recent notebooks (jump list)
- **iPad** `implemented` — `RecentNotebooksTracker` powers a recent list.
- **iPhone** `implemented`.
- **Mac** `partial` — tracker runs but no UI. **Recommendation:** File menu → "Open Recent" submenu (⌘⇧O), standard Mac idiom.

---

## 3. Library — notebooks

### 3.1 Create notebook
- **iPad** `implemented` — "+" in header → `LibraryViewModel.createNotebookWithFallback()`.
- **iPhone** `implemented`.
- **Mac** `implemented` — toolbar "+" and `⌘N`. `.macNewNotebook` notification round-trips.

### 3.2 Rename notebook
- **iPad** `implemented` — tap title → inline text field.
- **iPhone** `implemented`.
- **Mac** `partial` — verify rename gesture on grid cell. **UX:** double-click title inline (not a sheet).

### 3.3 Change cover tone
- **iPad** `implemented` — long-press notebook → cover picker sheet with 8 `NotebookCoverTone` tones.
- **iPhone** `implemented`.
- **Mac** `missing` — right-click → "Change cover" → 8-tone palette. **Priority high** — cover-tone is core to the editorial identity.

### 3.4 Delete / soft-delete notebook
- **iPad** `implemented` — swipe on cell or context menu → moves to trash.
- **iPhone** `implemented`.
- **Mac** `partial` — right-click → Delete. Verify it soft-deletes (does not hard-delete).

### 3.5 Duplicate notebook
- **iPad** `partial` — verify context menu item exists.
- **iPhone** `partial`.
- **Mac** `missing` — right-click → Duplicate. Should copy pages + preserve cover tone.

### 3.6 Move to subject
- **iPad** `implemented` — drag notebook onto sidebar subject row.
- **iPhone** `implemented` — long-press → "Move to…" sheet.
- **Mac** `partial` — drag-and-drop between grid and sidebar. Verify `onDrop` accepts internal notebook UUIDs, not just external file URLs.

### 3.7 Reorder notebooks
- **iPad** `implemented` — drag-reorder in grid.
- **iPhone** `implemented`.
- **Mac** `missing` — drag-reorder in grid. Currently sorted by default. **Recommendation:** add a `.dropDestination` to the grid.

### 3.8 Add / edit tags
- **iPad** `implemented` — `TagFilterSheet` + notebook detail.
- **iPhone** `implemented`.
- **Mac** `partial` — sheet exists but toolbar/menu entry to open it may be missing. **Recommendation:** notebook right-click → "Tags…".

### 3.9 Filter by tag
- **iPad** `implemented` — `TagFilterSheet`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify sheet presentation from a menu.

### 3.10 Pin / favourite notebook
- **iPad** `missing` — **recommended** — top of grid, "★" affordance.
- **iPhone** `missing`.
- **Mac** `missing`.

### 3.11 Notebook preview / peek
- **iPad** `implemented` — long-press = preview.
- **iPhone** `implemented`.
- **Mac** `missing` — space-bar quick look on selected cell (Finder-style). **Recommendation:** implement `.onKeyPress(.space)` on selected grid cell → floating peek window.

---

## 4. Library — subjects

### 4.1 Create subject
- **iPad** `implemented` — sidebar "+".
- **iPhone** `implemented`.
- **Mac** `partial` — verify sidebar "+" button; add `⌘⇧N`.

### 4.2 Rename subject
- **iPad** `implemented` — long-press row → inline field.
- **iPhone** `implemented`.
- **Mac** `partial` — right-click → Rename, or double-click.

### 4.3 Delete subject (with notebooks reassignment prompt)
- **iPad** `implemented` — sheet asks: move notebooks to "Unfiled" or delete all.
- **iPhone** `implemented`.
- **Mac** `partial` — same prompt must be an `NSAlert`-style confirm.

### 4.4 Reorder subjects
- **iPad** `implemented` — drag rows.
- **iPhone** `implemented`.
- **Mac** `partial` — drag rows in `SubjectSidebarView`. Verify.

### 4.5 Assign subject colour
- **iPad** `implemented` — colour swatches on subject.
- **iPhone** `implemented`.
- **Mac** `partial` — verify swatches render in sidebar.

---

## 5. Library — quizzes

### 5.1 Create quiz from notebook
- **iPad** `implemented` — `QuizBuilderView`.
- **iPhone** `implemented`.
- **Mac** `stub` — currently an empty state. **Recommendation:** allow creation (send pages to `AppleIntelligenceQuizGenerator`) — nothing about it needs a Pencil.

### 5.2 Play / take quiz
- **iPad** `implemented` — quiz player.
- **iPhone** `implemented`.
- **Mac** `stub` — recommend implementing; text-only interaction.

### 5.3 View quiz history / retake
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `stub`.

### 5.4 Delete quiz
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `stub`.

---

## 6. Library — trash

### 6.1 Open trash view
- **iPad** `implemented` — sidebar "Trash".
- **iPhone** `implemented`.
- **Mac** `implemented` — sidebar row.

### 6.2 Restore item
- **iPad** `implemented` — swipe or menu.
- **iPhone** `implemented`.
- **Mac** `partial` — right-click → Restore. Verify.

### 6.3 Empty trash
- **iPad** `implemented` — confirm alert.
- **iPhone** `implemented`.
- **Mac** `partial` — verify menu entry + confirm dialog.

### 6.4 Auto-purge after N days
- **iPad** `partial` — reconciliation runs on library open; verify N-day cutoff exists.
- **iPhone** `partial`.
- **Mac** `partial`.

---

## 7. Library — search & tags

### 7.1 Global search
- **iPad** `implemented` — search field in masthead → `SearchIndexService`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `⌘F` opens `SearchResultsView`. **UX gap:** should also work from menu bar quick capture (see §25).

### 7.2 Search within a notebook
- **iPad** `partial` — verify per-notebook filter.
- **iPhone** `partial`.
- **Mac** `partial` — `⌘F` inside `MacEditorView` should scope to the open notebook.

### 7.3 Spotlight system search
- **iPad** `implemented` — `SpotlightService` indexes notebooks.
- **iPhone** `implemented`.
- **Mac** `partial` — verify Spotlight registration on Mac target.

### 7.4 Filter by tag
- Covered in §3.9.

### 7.5 Search suggestions / recents
- **iPad** `missing` — **recommended** — show recent searches on focus.
- **iPhone** `missing`.
- **Mac** `missing`.

---

## 8. Library — Ask My Notes (AI)

### 8.1 Open Ask
- **iPad** `implemented` — `AskMyNotesView`.
- **iPhone** `partial` — verify layout on compact.
- **Mac** `missing` — **recommended high priority**; text-only surface, no Pencil needed. This is a Granola-style differentiator.

### 8.2 Enter question
- **iPad** `implemented`.
- **Mac** `missing`.

### 8.3 View grounded answer with citations
- **iPad** `implemented`.
- **Mac** `missing`.

### 8.4 Tap citation → jump to source page
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `missing` — Handoff-like jump to notebook + page.

### 8.5 Follow-up question / conversation
- **iPad** `partial` — verify multi-turn.
- **Mac** `missing`.

---

## 9. Editor — opening & pages

### 9.1 Open notebook to editor
- **iPad** `implemented` — cover flip animation.
- **iPhone** `implemented` — full-screen editor.
- **Mac** `implemented` — presented as `.sheet` at 900×640 min. **UX debate:** consider promoting to a full window on Mac (Granola pattern) so keyboard shortcuts feel native and the sheet dismiss gesture is less confusing. **Recommendation:** open editor in a **new window** via `openWindow(id: "editor", value: notebookId)`.

### 9.2 Add page
- **iPad** `implemented` — page strip "+" or menu.
- **iPhone** `implemented`.
- **Mac** `partial` — verify toolbar/menu entry + `⌘⇧P`.

### 9.3 Delete page
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — right-click in `PageStripView` → Delete.

### 9.4 Duplicate page
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `partial` — menu entry.

### 9.5 Reorder pages
- **iPad** `implemented` — drag in `PageStripView`.
- **iPhone** `implemented`.
- **Mac** `partial` — drag-reorder in strip on Mac.

### 9.6 Jump to page via minimap
- **iPad** `implemented` — `Minimap`.
- **iPhone** `partial` — verify visibility.
- **Mac** `missing` — recommend implementing on Mac too.

### 9.7 Zoom in/out on canvas
- **iPad** `implemented` — pinch.
- **iPhone** `implemented`.
- **Mac** `implemented` — `⌘=` / `⌘-` on toolbar. **UX gap:** add trackpad pinch and `⌘0` to reset.

### 9.8 Fit to page / actual size
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `missing` — `⌘0` reset zoom.

---

## 10. Editor — strokes (Apple Pencil)

_All iPad-only, by design. iPhone reads strokes but does not author (no Pencil). Mac reads strokes, does not author._

### 10.1 Draw with pencil
- **iPad** `implemented` — `ContinuousCanvasView` + PencilKit.
- **iPhone** `n/a` — `DeviceCapabilities.canDraw == false` on phone.
- **Mac** `n/a` — same.

### 10.2 Change tool (pen, marker, pencil, highlighter, eraser)
- **iPad** `implemented` — `ToolPaletteView`, `RadialToolWheel`.
- **iPhone** `n/a`.
- **Mac** `n/a`.

### 10.3 Change tool colour
- **iPad** `implemented` — `ColorPickerView`.
- others `n/a`.

### 10.4 Change tool thickness
- **iPad** `implemented`.

### 10.5 Erase stroke (object eraser)
- **iPad** `implemented`.

### 10.6 Lasso select strokes
- **iPad** `implemented` — `LassoOverlayView`.

### 10.7 Lasso group ops (move, resize, delete, colour swap)
- **iPad** `implemented` — `LassoGroupOps`.

### 10.8 Shape recognition
- **iPad** `implemented` — `ShapeRecognizer`.

### 10.9 Pencil squeeze quick action
- **iPad** `implemented` — `PencilSqueezeDetector` toggles tool.

### 10.10 Undo / redo
- **iPad** `implemented` — hardware buttons + toolbar.
- **iPhone** `implemented` for typed content.
- **Mac** `implemented` for typed content — `⌘Z` / `⌘⇧Z`.

---

## 11. Editor — text & sticky notes

### 11.1 Insert text element
- **iPad** `implemented` — toolbar → tap page.
- **iPhone** `implemented`.
- **Mac** `implemented` — double-click on page (also toolbar + `⌘T`).

### 11.2 Edit text (typing, cursor)
- **iPad** `implemented` — `TextEditorRepresentable`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `MacTextEditorSheet`. **UX:** consider inline editing instead of sheet on Mac; matches Craft/Bear.

### 11.3 Text formatting (bold, italic, size, colour)
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify toolbar in `MacTextEditorSheet`.

### 11.4 Move / resize text element
- **iPad** `implemented` — drag/handles.
- **iPhone** `implemented`.
- **Mac** `partial` — click-drag; verify handles.

### 11.5 Delete text element
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `implemented` — toolbar delete.

### 11.6 Sticky note (colored floating card)
- **iPad** `implemented` — `StickyNotes/`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify insert menu entry.

### 11.7 Text block (large formatted region)
- **iPad** `implemented` — `TextBlocks/`.
- **iPhone** `implemented`.
- **Mac** `partial`.

---

## 12. Editor — images & media

### 12.1 Insert image from Photos
- **iPad** `implemented` — `MediaPickerController` + PhotosUI.
- **iPhone** `implemented`.
- **Mac** `partial` — needs `NSOpenPanel` fallback (no Photos picker on Mac by default). Verify path.

### 12.2 Insert image from camera
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `n/a` — no camera app parity; skip.

### 12.3 Insert image from Files / drag-drop
- **iPad** `implemented` — drop on page.
- **iPhone** `partial`.
- **Mac** `implemented` — `handleLibraryDrop` and `MacEditorView` drop targets.

### 12.4 Move / resize / rotate image
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify rotate handle.

### 12.5 Delete image
- Same as above.

### 12.6 Crop image
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `missing`.

### 12.7 Extract text from image (Vision OCR)
- **iPad** `implemented` — `HandwritingOCRService`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify Vision availability; recommend menu entry.

---

## 13. Editor — PDF import & annotation

### 13.1 Import PDF as new notebook
- **iPad** `implemented` — Files picker.
- **iPhone** `implemented`.
- **Mac** `implemented` — drag PDF onto library. **UX gap:** also allow via `File → Import PDF…` menu.

### 13.2 Import PDF as page(s) into current notebook
- **iPad** `implemented` — `PDFPagePickerSheet`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify sheet on Mac.

### 13.3 Annotate PDF page with strokes
- **iPad** `implemented`.
- **iPhone** `n/a` — no Pencil.
- **Mac** `n/a` — no Pencil.

### 13.4 Add text on top of PDF
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `implemented` — via double-click.

### 13.5 Extract text from PDF (search)
- **iPad** `implemented` — PDFKit text layer indexed by `SearchIndexService`.
- **iPhone** `implemented`.
- **Mac** `implemented`.

### 13.6 Rearrange PDF pages
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `missing` — recommend.

---

## 14. Editor — audio, dictation, lecture

### 14.1 Voice memo on a page
- **iPad** `implemented` — `AudioElements/`.
- **iPhone** `implemented` — recent `iphone-support` branch enabled this.
- **Mac** `implemented` — `MacRecordingSession` `.voiceMemo` mode; playback via `MacAudioPlayer` (`MacRendering.swift`, doc-mode `MacDocBlock`).

### 14.2 Dictation into text element
- **iPad** `implemented` — `DictationFlowCommit`; on stop, `TranscriptStructurer` reflows the block (verbatim) and `MeetingSummaryCommit` prepends a SUMMARY into the transcript element.
- **iPhone** `implemented` — post-fix.
- **Mac** `implemented` — "Meeting Transcription" (`MacRecordingSession` `.transcription` mode) streams words into the page; on stop, structure + `MacMeetingSummary` block above the transcript.

### 14.3 Lecture mode (long-form recording + live transcription)
- **iPad** `implemented` — `LectureRecorder`.
- **iPhone** `implemented`.
- **Mac** `implemented` — same `LectureRecorder` engine drives Meeting Transcription; utterances continue with a space, new paragraph only on a ≥2.5 s pause (shared behaviour, all platforms).

### 14.4 Play back recording
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `MacAudioPlayer` on the audio strip (canvas + doc mode).

### 14.5 Scrub / seek transcript
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `missing`.

### 14.6 Delete recording
- Same treatment across.

### 14.7 Export transcript as text
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `missing` — recommend.

---

## 15. Editor — highlights, shapes, annotations

### 15.1 Highlight text
- **iPad** `implemented` — `HighlightElements/`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 15.2 Draw shape (auto-recognised)
- **iPad** `implemented` — `ShapeRecognizer`.
- **iPhone** `n/a`.
- **Mac** `n/a` — but consider "insert shape from menu" (rectangle, circle, arrow) as a keyboard-first affordance.

### 15.3 Free annotation notes
- **iPad** `implemented` — `Annotations/`.
- **iPhone** `implemented`.
- **Mac** `partial`.

---

## 16. Editor — AI (summarize, ask, agent)

### 16.1 Summarize current page
- **iPad** `implemented` — `SummarizePageView`.
- **iPhone** `implemented`.
- **Mac** `missing` — recommend; trivially portable.

### 16.2 Ask about page (contextual AI)
- **iPad** `implemented` — `AgentBannerView` + Foundation Models.
- **iPhone** `partial`.
- **Mac** `missing`.

### 16.3 Generate quiz from page(s)
- **iPad** `implemented` — `AppleIntelligenceQuizGenerator`.
- **iPhone** `implemented`.
- **Mac** `missing`.

### 16.4 Rewrite / clean up handwriting to text
- **iPad** `partial` — via OCR path.
- others `partial`.

---

## 17. Editor — customisation & cover

### 17.1 Edit notebook cover (title, wordmark, tone)
- **iPad** `implemented` — `Cover/`.
- **iPhone** `implemented`.
- **Mac** `missing` — recommend; sheet with the 8 tones + title field.

### 17.2 Customise page template (grid, dot, blank, lined)
- **iPad** `implemented` — `CustomisePanel`.
- **iPhone** `implemented`.
- **Mac** `missing` — recommend menu entry.

### 17.3 Change page background colour
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `missing`.

---

## 18. Editor — export & share

### 18.1 Export current page as PDF
- **iPad** `implemented` — `ExportService`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `MacExportSheet`.

### 18.2 Export whole notebook as PDF
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `implemented`.

### 18.3 Export as image (PNG)
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify PNG option in export sheet.

### 18.4 Share via system share sheet
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — `NSSharingServicePicker`; verify.

### 18.5 Print
- **iPad** `implemented` — UIKit print.
- **iPhone** `implemented`.
- **Mac** `missing` — `⌘P` should route through `NSPrintOperation` on the current page/notebook.

### 18.6 Copy page as image to clipboard
- **iPad** `partial`.
- **iPhone** `partial`.
- **Mac** `missing` — recommend `⌘⇧C`.

### 18.7 Export as Markdown (typed text + transcripts only)
- All devices `missing` — **recommend**; big Granola parity win.

---

## 19. Settings

### 19.1 Open settings
- **iPad** `implemented` — `SettingsView`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `⌘,` → `MacSettingsView`.

### 19.2 Appearance (theme, contrast, motion)
- **iPad** `implemented` — `AppearanceSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial` — verify same section is rendered.

### 19.3 Change app icon
- **iPad** `implemented` — `IconPreviewView`.
- **iPhone** `implemented`.
- **Mac** `n/a`.

### 19.4 Pencil settings
- **iPad** `implemented` — `PencilSettingsView`.
- **iPhone** `n/a`.
- **Mac** `n/a`.

### 19.5 Audio settings (mic, transcription)
- **iPad** `implemented` — `AudioSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial` — recommend expose.

### 19.6 Intelligence / AI settings (on-device toggle, models)
- **iPad** `implemented` — `IntelligenceSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 19.7 Cloud settings (iCloud status, resync)
- **iPad** `implemented` — `CloudSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 19.8 Storage settings (used space, cache clear)
- **iPad** `implemented` — `StorageSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 19.9 About (version, credits)
- All `implemented`.

### 19.10 Privacy policy view
- All `implemented`.

### 19.11 Debug menu (only in debug builds)
- **iPad** `implemented` — `DebugSettingsView`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 19.12 Style guide (design-system inspector)
- **iPad** `implemented` — `StyleGuideView`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 19.13 Sign out / reset iCloud
- All `partial` — verify path.

### 19.14 Multipeer pairing management (see peers, unpair)
- All `partial` — `MultipeerPairingStore` powers this; verify UI on each device.

---

## 20. Sync — CloudKit & Multipeer

### 20.1 CloudKit background sync
- All `implemented` — `CloudSyncManager`.

### 20.2 Sync status banner
- **iPad** `implemented` — `SyncStatusIndicator`.
- **iPhone** `implemented`.
- **Mac** `implemented` — `MacSyncBanner` (hairline editorial style).

### 20.3 Force resync
- **iPad** `implemented` — Settings → Cloud.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 20.4 Multipeer discovery / advertise
- **iPad** `implemented` — `MultipeerSyncService`.
- **iPhone** `implemented`.
- **Mac** `implemented` — with Bonjour + local network entitlements.

### 20.5 Peer pairing / trust
- All `partial` — verify pairing UI is reachable on Mac.

### 20.6 Conflict resolution (last-writer-wins + surface)
- All `partial` — conflict UI is a known gap; **recommend** a "resolve conflict" surface in Settings → Cloud.

---

## 21. Handoff & continuity

### 21.1 Handoff editing a page from iPad → Mac
- **iPad** `implemented` — publishes `MacHandoff.activityType` `NSUserActivity`.
- **iPhone** `partial` — verify publisher.
- **Mac** `implemented` — `MacAppDelegate.application(_:continue:...)` receives and posts `.macOpenHandoffPage`.

### 21.2 Handoff Mac → iPad
- **Mac** `partial` — verify `NSUserActivity` publisher in `MacEditorView`.
- **iPad** `partial` — receiver.

### 21.3 Universal clipboard
- All `n/a` — system-managed; no work needed.

### 21.4 Deep link (URL scheme) to notebook / page
- All `missing` — **recommend**: `ceciliasnotes://notebook/{uuid}/page/{uuid}` opens the right surface; enables Shortcuts, browser bookmarks, cross-app links.

---

## 22. Widgets & complications

### 22.1 Home screen widget — recent notebooks
- **iPad** `implemented`.
- **iPhone** `implemented`.
- **Mac** `partial` — macOS Sonoma+ supports the same widget target; verify.

### 22.2 Lock screen widget
- **iPhone** `implemented`.
- **iPad** `implemented`.
- **Mac** `n/a`.

### 22.3 StandBy widget (iPhone charging landscape)
- **iPhone** `partial` — verify.
- others `n/a`.

### 22.4 Widget → deep-link into notebook
- Depends on §21.4; **currently missing**.

---

## 23. System integrations

### 23.1 Spotlight indexing
- **iPad** `implemented` — `SpotlightService`.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 23.2 App Intents / Shortcuts
- All `missing` — **recommend** intents: "Create new note", "Open notebook", "Ask my notes".

### 23.3 Share extension (receive text/URL from other apps)
- **iPad** `missing`.
- **iPhone** `missing`.
- **Mac** `n/a` (macOS uses Services menu).

### 23.4 Services menu (Mac)
- **Mac** `missing` — "New note from selection" service.

### 23.5 Files provider (browse notebooks from Files app)
- All `missing` — costly; deprioritise unless requested.

### 23.6 Drag from library to another app
- **iPad** `partial` — verify drag payload.
- **iPhone** `n/a`.
- **Mac** `partial`.

---

## 24. Accessibility & input

### 24.1 VoiceOver navigation of library
- All `partial` — audit needed. See `AccessibilityExtensions.swift`.

### 24.2 Dynamic Type scaling
- **iPad** `implemented` — Zara type respects category caps.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 24.3 Reduce motion
- **iPad** `implemented` — cover-flip animation respects it.
- **iPhone** `implemented`.
- **Mac** `partial`.

### 24.4 Keyboard-only navigation
- **iPad** `partial` — Smart Keyboard shortcuts exist for some flows.
- **iPhone** `n/a`.
- **Mac** `partial` — **recommend** full keyboard nav (Tab loop through sidebar/grid/editor).

### 24.5 Hardware keyboard shortcuts
- **iPad** `implemented` — some.
- **Mac** `partial` — `⌘N`, `⌘E`, `⌘T`, `⌘,`, `⌘=`, `⌘-`. **Missing:** `⌘F`, `⌘⇧F` (find in notebook), `⌘⌥S`, `⌘0`, `⌘P`, `⌘⇧O`, `⌘⇧N`, `⌘K` (command palette).

### 24.6 Trackpad gestures
- **iPad** `implemented`.
- **Mac** `partial` — pinch-zoom on canvas is missing.

---

## 25. Mac-only flows benchmarked to Granola

_Granola's differentiator: fast, keyboard-first, meeting-centric capture. Cecilia's Notes is not a meeting app, but the Mac's job is "capture during work" and these idioms translate._

### 25.1 Menu bar quick capture
- **Mac** `missing` — **high-priority recommendation**. Menu bar icon opens a compact popover: title + body, one keyboard shortcut (⌥⌘Space), saves to "Unfiled" notebook and dismisses. Granola's core surface.

### 25.2 Global hotkey (system-wide) to open the app / new note
- **Mac** `missing` — `⌥⌘Space` toggles quick capture; user-configurable in Settings.

### 25.3 Command palette (⌘K)
- **Mac** `missing` — searches subjects, notebooks, pages, actions ("Change cover to Midnight", "Start lecture"). Fastest way to reach any flow without mousing.

### 25.4 Multi-window
- **Mac** `missing` — open two notebooks side-by-side (`File → New Window` or double-click). Currently editor is a modal sheet — see §9.1 recommendation.

### 25.5 Calendar-linked notebooks (Granola parity)
- **Mac** `missing` — optional: EventKit integration. On a calendar event start, offer "Take notes for this meeting" → creates a notebook titled after the event. **Consider only if user wants meeting-notes positioning.**

### 25.6 Templates
- **Mac** `missing` — "New from template" (meeting, lecture, journal). Templates seed the first page with typed text scaffolding. Cross-device once built.

### 25.7 Sidebar smart lists
- **Mac** `missing` — "Today", "This week", "Untagged", "Recording in progress". Zero-config filters.

### 25.8 Focus mode / hide chrome
- **Mac** `missing` — `⌃⌘F` hides sidebar + toolbar for distraction-free typing. Matches Ulysses / iA Writer.

### 25.9 Native find-and-replace in text elements
- **Mac** `missing` — `⌘F` inside the text editor sheet.

### 25.10 Live-collaboration cursor (long-term)
- **Mac** `missing` — deprioritise; requires backend.

---

## 26. Recommended missing flows

_Pulled together from the "missing" flags above. Prioritise the top block; the bottom block is nice-to-have._

### Priority — do soon
- **3.3** Cover-tone change on Mac (right-click menu)
- **8.1–8.5** Ask My Notes on Mac
- **14.3** Lecture mode on Mac
- **17.1** Notebook cover editor on Mac
- **21.4** Deep link URL scheme (unlocks widgets, Shortcuts)
- **23.2** App Intents / Shortcuts (system-level accessibility)
- **25.1** Menu bar quick capture (Mac)
- **25.3** Command palette `⌘K` (Mac)
- **24.5** Full Mac keyboard-shortcut set

### Nice to have
- **3.10** Pin / favourite notebook
- **7.5** Search suggestions / recents
- **12.6** Image crop
- **13.6** Rearrange PDF pages
- **18.7** Export as Markdown
- **20.6** Conflict-resolution UI
- **25.5** Calendar-linked notebooks
- **25.6** Templates
- **25.7** Smart lists
- **25.8** Focus mode

---

_Regenerate the code map after any flow implementation: `python3 Documentation/tools/build_code_graph.py`._

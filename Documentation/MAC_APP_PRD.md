# Cecilia's Notes for Mac — Product Requirements Document

A reference for building the native Mac companion to Cecilia's Notes.
Written to be self-sufficient: an implementer (human or LLM) should
be able to ship the v1 app from this document plus the existing
codebase without further clarifying calls. Bullet points and short
paragraphs are preferred over prose.

Companion documents:
- [ARCHITECTURE.md](ARCHITECTURE.md) — the iOS/iPadOS baseline.
  Everything in there is the source of truth for the shared data
  layer, schema, and sync protocol.
- [MULTIPEER_SYNC_PROTOCOL.md](MULTIPEER_SYNC_PROTOCOL.md) — the
  peer-to-peer handoff that will be extended to Mac in v1.1.
- [MEDIA_SUBSYSTEM_AUDIT.md](MEDIA_SUBSYSTEM_AUDIT.md) — the
  media/audio/PDF file tree layout the Mac app inherits verbatim.

---

## 1. Vision

- **Goal.** Cecilia's Notes should be reachable from every screen
  its owner uses — the iPad they write on, the iPhone they carry,
  and the Mac they work on. The Mac app is the third and final
  device in that set for v1.
- **Positioning.** The Mac app is not a "port" of the iPad app.
  It is the **keyboard-and-pointer surface** for the same notebook
  library. It optimises for reading, searching, organising,
  exporting, and typing; handwriting and drawing remain iPad-first.
- **Non-goal.** We do not pursue web, Windows, or Android in this
  document. Cecilia's Notes stays a first-party Apple product.
- **Success criteria (measured at 90 days post-launch).**
  - A user with an active iPad notebook can open the same notebook
    on their Mac within 60 seconds of first launch, with zero
    manual sync intervention.
  - ≥80% of the top-30 iPad flows have a native Mac equivalent
    that a Mac-native user would recognise as idiomatic (not just
    Catalyst-rendered iPad chrome).
  - Zero data-loss reports where the Mac was involved.

---

## 2. Users and jobs

### 2.1 Primary persona
- **Cecilia** (composite): a student / researcher / professional
  who takes handwritten notes on iPad and later needs to read,
  search, cross-reference, and share them from a Mac.

### 2.2 Top jobs on Mac (ranked by frequency)
1. **Open a notebook and read it.** Same content as iPad, high
   fidelity — strokes render pixel-accurate, PDFs render at full
   quality, images crisp on Retina.
2. **Search across every notebook.** Full-text over OCR'd
   handwriting, typed text, PDF text layers, image alt-text,
   quiz questions. Global, one keystroke away (`⌘⇧F`).
3. **Type into an existing page.** Insert text elements from the
   keyboard, edit existing ones, paste rich content.
4. **Import files.** Drag a PDF from Finder onto a notebook →
   new page(s). Drag an image onto a page → placed at cursor.
   Drop a folder of images → a new notebook.
5. **Export.** PDF, image bundle, individual page image, Markdown
   with embedded assets. To Finder, Mail, Messages, Notes.
6. **Organise.** Rename, tag with subjects/folders, reorder pages,
   duplicate, archive, delete. Multi-select in the sidebar.
7. **Study.** Open a quiz on Mac; keyboard-answer through it.
8. **Handoff to iPad.** Currently reading a page on Mac → tap
   Handoff on the iPad → land on the same page, scrolled to the
   same offset.

### 2.3 Deliberately out of scope for v1
- Handwriting input (no native pen support on non-touch Macs;
  Sidecar / Universal Control routes Apple Pencil back to the iPad
  app anyway).
- On-device Foundation Models AI features (the iPad app runs these
  via Apple Intelligence; v1 Mac reads/renders the outputs but
  does not generate new ones). Revisit in v1.2 once macOS Apple
  Intelligence parity is confirmed on the target hardware.
- Live dictation on Mac. Voice notes on Mac defer to v1.1.

---

## 3. Platform + distribution

- **Deployment target.** macOS 15.0 (Sequoia). One version behind
  the current major keeps the addressable install base wide
  without forcing a Sonoma dual-track.
- **Architecture.** Apple silicon + Intel universal binary. Intel
  build supported through v1; may be dropped at v2.
- **Distribution.** Mac App Store, **Universal Purchase** with the
  existing iOS app (`app.ceciliasnotes`) — a user who bought the
  iPad app gets Mac free. Bundle ID stays the same across
  platforms; Xcode uses the destination to differentiate.
- **Signing / sandbox.** App Sandbox on. Hardened runtime on.
  Entitlements limited to: iCloud (CloudKit + key-value store +
  ubiquity container), App Groups (`group.app.ceciliasnotes`),
  Camera (off — deferred), Microphone (off — deferred),
  User-Selected Files (read/write, for import/export via Finder),
  Downloads Folder (read/write, for default export destination).
- **Not Catalyst.** The Mac app is a **native AppKit + SwiftUI
  target**, not a Mac Catalyst repackage of the iPad app. Catalyst
  produces a hybrid chrome that reads as "iPad app in a window" —
  we want a native Mac app. Shared code goes through the Core
  layer (§5).
- **NOT a document-based app.** The library / notebook is the
  document model; individual notebooks are not `.ceciliasnotes`
  files a user manages in Finder. Rationale: the iOS app is a
  library app, and duplicating the library-vs-documents mental
  model on Mac splits the user's context. Export produces a `.pdf`
  or `.zip` bundle; import produces a new notebook in the library.

---

## 4. Feature matrix (Mac v1 vs iPad)

Legend: ✅ full parity · 🟨 read-only · ⏳ deferred to v1.1+ ·
❌ out of scope on Mac.

| Area | Feature | Mac v1 | Notes |
|---|---|---|---|
| Library | Browse subjects / folders / notebooks | ✅ | Sidebar-first layout. |
| Library | Create subject / folder / notebook | ✅ | |
| Library | Rename / recolour / soft-delete / restore | ✅ | |
| Library | Empty trash | ✅ | |
| Library | Multi-select in sidebar | ✅ | Mac-specific: shift/cmd click. |
| Library | Universal search (`⌘⇧F`) | ✅ | See §7. |
| Editor | Render strokes | ✅ | Read-only in-body strokes; edits deferred. |
| Editor | Render images, PDFs, shapes, stickies, text, audio | ✅ | |
| Editor | Edit text elements | ✅ | Type / paste / rich formatting. |
| Editor | Insert new text element | ✅ | Click empty area with text tool. |
| Editor | Insert new image element | ✅ | Drag from Finder or paste. |
| Editor | Insert PDF as new page(s) | ✅ | Drag from Finder. |
| Editor | Insert sticky note | ✅ | |
| Editor | Insert shape | 🟨 | Read-only in v1; edit in v1.1. |
| Editor | Draw strokes | ❌ | No pen surface on Mac. Sidecar path routes to iPad. |
| Editor | Erase strokes | ❌ | Same reason. |
| Editor | Lasso select strokes | ❌ | Same reason. |
| Editor | Lasso select images / shapes / stickies | ✅ | Pointer-driven marquee. |
| Editor | Play back audio elements | ✅ | AVKit `AVPlayer` view. |
| Editor | Record dictation | ⏳ | v1.1. |
| Editor | Record voice notes | ⏳ | v1.1. |
| Editor | Auto-transcribe | 🟨 | Reads existing transcripts; on-device transcription of a Mac-recorded file lands in v1.1. |
| Editor | Zoom / pan | ✅ | Two-finger pinch, `⌘=` / `⌘−`. |
| Editor | Page strip | ✅ | Bottom or right, user-choice. |
| Editor | Add page | ✅ | |
| Editor | Templates picker | ✅ | |
| Editor | Undo / redo | ✅ | System `⌘Z` / `⌘⇧Z`. |
| Quiz | Take a quiz | ✅ | Keyboard-answer flow. |
| Quiz | Generate a quiz | ❌ | Foundation Models on iPad only for v1. |
| Quiz | Review results | ✅ | |
| Export | PDF | ✅ | |
| Export | Image (single page / all pages) | ✅ | |
| Export | Markdown bundle | ✅ | |
| Export | Share via system share sheet | ✅ | `NSSharingServicePicker`. |
| Import | PDF → new notebook or new pages | ✅ | Drag or `⌘O`. |
| Import | Image → new element or new notebook | ✅ | |
| Import | Folder of images → new notebook | ✅ | |
| Sync | CloudKit private database | ✅ | Same schema and container as iPad. |
| Sync | Multipeer nearby-device handoff | ⏳ | v1.1; iPad ↔ iPad exists, Mac joins in v1.1. |
| Sync | Universal Clipboard | ✅ | Free from AppKit; nothing to build. |
| Sync | Handoff to iPad (open the same notebook / page) | ✅ | `NSUserActivity`. |
| Settings | Library home preferences | ✅ | |
| Settings | Sync status + escape hatch | ✅ | |
| Settings | Export defaults | ✅ | |
| Settings | About / support / privacy | ✅ | |

---

## 5. Architecture

### 5.1 Target layout

```
CeciliasNotes.xcodeproj
├── CeciliasNotes            ← iOS app target (existing)
├── CeciliasNotesMac         ← new: macOS app target (this doc)
├── CeciliasNotesCore        ← new: shared framework (Swift package)
├── CeciliasNotesWidget      ← iOS widget (existing)
└── CeciliasNotesShareExt    ← iOS share extension (existing)
```

- **CeciliasNotesCore** is a new Swift package inside the same
  workspace. All data models, storage services, sync managers,
  export logic, quiz logic, and stroke-decoding utilities move
  there. Both platform targets depend on it.
- Neither platform target shadows Core's symbols; UI-layer code
  stays in its target and imports Core.
- The move is mechanical (no behaviour changes) and happens as the
  first Mac-specific commit. It is a prerequisite for the rest of
  the work.

### 5.2 What is shared vs. platform-specific

**Shared (Core).**
- SwiftData `@Model` types + schema versions.
- `StorageService`, `MediaStorage`, `PageElementRepository`.
- `CloudSyncManager` (CloudKit account status, container init,
  local-only fallback).
- `SearchIndexService` (OCR / text index maintenance).
- `PDFReferenceImporter`, `AudioContent` transcription plumbing.
- `QuizEngine` (scoring, session state).
- `ExportService` for PDF and image bundles (rendering uses
  platform types — see below).
- Stroke decoding (`PKDrawing(data:)`).
- Cover art palette (`CoverToneStore`), theme tokens, colour
  primitives — kept in Core as raw values; platform-specific
  wrappers turn them into `UIColor` / `NSColor` at the target
  boundary.

**iOS-only.**
- PencilKit input paths.
- Apple Pencil hover, palm rejection, tool picker.
- `LectureRecorder`, `RecordingSession` (recording surfaces).
- Foundation Models AI code (until v1.2 Mac).
- WidgetKit tiles.

**macOS-only.**
- Menu bar, main window, sidebar, three-pane layout.
- `NSToolbar`, `NSSharingServicePicker`, `NSSavePanel`,
  `NSOpenPanel`, `NSAlert`, `NSTouchBar` (deferred).
- Drag-and-drop from Finder (`NSItemProvider` / `NSPasteboard`).
- Handoff `NSUserActivity` publishing.
- Keyboard shortcut catalogue (`KeyboardShortcuts.swift`).
- Editor renderers that project the shared `PageElement` tree
  onto `NSView`s (see §6.3).

### 5.3 Rendering strategy

- **Strokes.** `PKDrawing.image(from:scale:userInterfaceStyle:)`
  is available on macOS — a rasterised image, but pixel-accurate
  and cheap. v1 uses it. v1.2 revisits vector rendering via a
  custom `CAShapeLayer` bake if fidelity complaints surface.
  Rationale: no PencilKit `PKCanvasView` exists on macOS, so we
  render the persisted drawing rather than trying to reproduce the
  input stack.
- **Text elements.** `NSTextView` in a subclassed container that
  hosts one attributed string per element. Reuses the same text-
  attribute schema as the iOS `UITextView` path so a text element
  edited on Mac round-trips visually on iPad.
- **Images.** `NSImageView` with `imageScaling = .scaleProportionallyUpOrDown`,
  layer-backed for GPU compositing. Same normalised coordinate
  system as iPad — the element rect is `(normalizedX, normalizedY,
  normalizedWidth, normalizedHeight)` and the containing page
  view maps into points.
- **PDF pages.** `PDFKit` (available on macOS) renders the page at
  the current zoom; the underlying `PDFDocument` is cached per
  reference so the same doc opened on ten pages shares one buffer.
- **Sticky notes, shapes.** SwiftUI. Small enough that the SwiftUI
  render cost is neglible.
- **Audio elements.** SwiftUI plays back via `AVPlayer`. The
  waveform strip uses the same offline-rendered path as iOS
  (`WaveformRenderer` moves to Core).
- **Page background templates** (grid, ruled, dot, blank, PDF-
  backed) — a shared `PageTemplate` type in Core exposes a
  `render(into: CGContext, size: CGSize)` method both platforms
  call.

### 5.4 Data flow and sync

- **Same CloudKit container** as iPad
  (`iCloud.app.ceciliasnotes`). SwiftData's CloudKit backing sees
  Mac and iPad as two devices of the same account, and syncs the
  private database in the background.
- **First-launch bootstrap.** On sign-in, the Mac subscribes to
  the private database. Existing records download in the
  background; the library shows a "syncing" state on the sidebar
  root until the first fetch completes. No blocking modal — the
  user sees whatever has already downloaded and the rest fills in.
- **Escape hatch.** The iOS `swiftDataCloudKitDisabledKey`
  preference is honoured on Mac too. If the container is stuck,
  the user can open Settings → iCloud → "Disable database sync
  (advanced)" and continue working local-only. Same UserDefaults
  key + `App Groups` sharing means a preference set on iPad
  reflects on Mac (and vice versa) once the group container is
  available.
- **Media files.** The ubiquity container (`iCloud~app~ceciliasnotes`
  Documents folder) is the sync channel for images, PDFs, and
  audio. `CloudSyncManager` on Mac watches for
  `NSMetadataQuery` updates the same way iOS `CeciliasNotesFileWatcher`
  does. On-disk layout under `MediaAttachments/` is identical to
  iPad.
- **Two-way clock skew.** SwiftData last-write-wins remains the
  conflict-resolution primitive. No custom merge logic.

### 5.5 Sandbox implications

- The App Sandbox prevents the Mac app from touching arbitrary
  filesystem paths. Import via `NSOpenPanel` gives us a
  security-scoped bookmark; we resolve it, copy the bytes into
  the sandbox container (`MediaAttachments/`), and drop the
  bookmark. From then on the file is ours.
- Export via `NSSavePanel` similarly hands us a
  security-scoped URL for the destination; we write, close,
  drop.
- Drag-and-drop of Finder items provides a security-scoped URL
  in the `NSPasteboard`. Same copy-into-sandbox pattern.
- The **CloudKit ubiquity container is accessible** to the sandbox
  because it belongs to the app's container. Same behaviour as
  iOS.

---

## 6. UX and visual design

### 6.1 Window model

- **Single primary window** at launch. Three-pane layout with
  `NSSplitViewController`:
  ```
  ┌────────────┬───────────────┬──────────────────┐
  │ Sidebar    │ Notebook list │ Editor / detail  │
  │ (subjects, │  (notebook    │  (pages, canvas) │
  │  folders)  │   thumbnails) │                  │
  └────────────┴───────────────┴──────────────────┘
  ```
- **Sidebar** shows: All Notes, Recents, Subjects (expandable
  → folders → notebooks), All Subjects, All Quizzes, Trash.
  Vibrant, translucent (`NSVisualEffectView` blur mode
  `.sidebar`).
- **Notebook list** shows the notebooks under the currently-
  selected sidebar item. Two view modes: grid (cover art
  thumbnails, iPad-style) and list (compact rows with subject
  chip). User preference persists per source.
- **Editor pane** hosts a single notebook — the continuous
  page scroll, page strip along the trailing edge, floating
  toolbar top-right.
- **Multi-window.** A second notebook opens in a new window
  (`⌘⌥N` on a notebook row, or "Open in New Window" from the
  context menu). Each window is independent — its own toolbar,
  its own zoom, its own scroll position. No window-shared state
  besides the underlying data.
- **Full-screen** hides the sidebar by default; user can bring
  it back with `⌥⌘S`.

### 6.2 Toolbar

- Native `NSToolbar`, unified with the titlebar in the Big Sur
  style. Items:
  - **Back / forward** (navigation stack: sidebar → notebook →
    page. Optional; can be a user preference).
  - **View mode** (grid / list) — visible only when the notebook
    list is focused.
  - **Zoom** (out / fit / in) — visible only in editor.
  - **Insert menu** — text, image, sticky, PDF, shape, audio (audio
    disabled in v1). Opens a popover with icons.
  - **Share** — `NSSharingServicePicker` seeded with the current
    page as PDF.
  - **Export** — opens an inline sheet, `⌘E`.
  - **Search** field on the trailing side, always visible when the
    sidebar is showing.
- Customisation via View → Customize Toolbar…

### 6.3 Editor pane detail

- **Scroll model.** `NSScrollView` with a continuous vertical
  stack of `PageHost` views, matching iPad `ContinuousCanvasView`
  semantically. Zoom via magnify gesture; scroll wheel scrolls,
  `⌥`-scroll zooms.
- **Page strip.** Vertical along the trailing edge (default),
  optionally horizontal along the bottom (matches iPad default).
  Right-click a page strip cell for its context menu (duplicate,
  delete, move, insert page above/below, change template).
- **Selection.** Click an element to select. Multi-select with
  `⌘`-click and marquee (drag empty area). Selected elements get
  the same handle chrome as iPad, adapted for pointer sizing.
- **Text editing.**
  - Text tool active + click empty area → new text element
    inserted at click point, immediately focused.
  - Any tool active + double-click a text element → focus + edit.
  - `Esc` commits and deselects.
  - `⌘B`, `⌘I`, `⌘U` for bold / italic / underline.
  - Standard `NSTextView` bindings (`⌥←`, `⌥→` for word jumps,
    etc.).
- **Undo.** `UndoManager` per document, wired to `⌘Z` / `⌘⇧Z`.
  Shared undo groups exist for compound ops (paste with images,
  multi-delete).
- **Drop targets.**
  - Drop a PDF onto the sidebar / notebook list → new notebook.
  - Drop a PDF onto the editor → sheet: "Insert as new pages" (at
    end / after current) or "Attach as reference PDF" (adds a
    PDF-backed page group).
  - Drop an image onto the editor → placed at cursor.
  - Drop text onto the editor → new text element.

### 6.4 Sidebar and library

- The sidebar is a `NSOutlineView` wrapped in SwiftUI via
  `NSViewControllerRepresentable`. Native disclosure triangles,
  drag-to-reorder subjects/folders, drop targets accepting
  notebook rows.
- **Right-click / control-click** context menus on every row.
- **Search field** in the sidebar header for scoping ("search
  in this subject").
- **Trash** at the bottom, always. Selecting Trash shows deleted
  items in the notebook pane with a "Restore" action; the
  30-day reaper (per iOS ARCHITECTURE.md) applies unchanged.

### 6.5 Typography, colours, and materials

- Reuse the iOS type ramp constants from `DesignSystem`, wrapped
  in Mac-appropriate defaults: system-font ramp keyed off
  `.body`, `.title2`, `.headline`, etc. No custom font families
  in v1.
- Use **`NSColor.systemAccentColor`** wherever iOS uses the
  accent tint; users pick their system accent in System Settings.
- Materials: `NSVisualEffectView` with `.sidebar` for sidebar,
  `.headerView` for toolbar, `.contentBackground` for editor
  chrome. Dark mode and light mode are both first-class; the
  visual identity from iOS transfers cleanly.
- **Cover art** for notebooks re-uses `CoverToneStore` — same
  16-tone palette on both platforms so an iPad-generated notebook
  looks the same on Mac.

### 6.6 Menu bar

Top-level menus, in order:

- **Cecilia's Notes** — About, Settings…, Services, Hide, Quit.
- **File** — New Notebook `⌘N`, New Window `⌘⌥N`, Open…
  `⌘O`, Import PDF…, Import Image…, Close Window `⌘W`, Save
  Snapshot… `⌘S`, Export… `⌘E`, Share… `⌘⇧S`, Print… `⌘P`.
- **Edit** — Standard `NSTextView` items plus Duplicate `⌘D`,
  Delete, Select All `⌘A`. Undo `⌘Z`, Redo `⌘⇧Z`.
- **Insert** — Text `⌘T`, Image `⌘⇧I`, Sticky Note `⌘⇧K`, Page
  Above, Page Below `⌘⏎`, PDF Reference, Shape.
- **View** — Zoom In `⌘=`, Zoom Out `⌘−`, Actual Size `⌘0`,
  Fit `⌘9`, Toggle Sidebar `⌘⌥S`, Toggle Page Strip, Show
  Rulers `⌘R`, Enter Full Screen `⌘⌃F`.
- **Notebook** — Rename, Change Cover…, Change Template…,
  Move to Subject ▶, Move to Folder ▶, Duplicate `⌘⇧D`,
  Archive, Move to Trash `⌫`.
- **Quiz** — Take Quiz…, Show Results.
- **Window** — Standard.
- **Help** — Cecilia's Notes Help, Contact Support, Release
  Notes.

### 6.7 Keyboard shortcuts (canonical list)

| Shortcut | Action |
|---|---|
| `⌘N` | New notebook |
| `⌘⌥N` | New window (from a selected notebook) |
| `⌘O` | Open (file picker → import) |
| `⌘S` | Save snapshot / commit dirty edits |
| `⌘W` | Close window |
| `⌘Q` | Quit |
| `⌘,` | Settings |
| `⌘F` | Find in current notebook |
| `⌘⇧F` | Universal search |
| `⌘E` | Export |
| `⌘⇧S` | Share |
| `⌘P` | Print |
| `⌘Z` / `⌘⇧Z` | Undo / Redo |
| `⌘C` / `⌘V` / `⌘X` | Copy / Paste / Cut |
| `⌘A` | Select all elements on current page |
| `⌘D` | Duplicate selection |
| `⌫` / `⌘⌫` | Delete selection / move notebook to trash |
| `⌘T` | Insert text element |
| `⌘⇧I` | Insert image |
| `⌘⇧K` | Insert sticky note |
| `⌘⏎` | Add new page below current |
| `⌘=` / `⌘−` / `⌘0` / `⌘9` | Zoom in / out / 100% / fit |
| `⌘⌥S` | Toggle sidebar |
| `⌘R` | Toggle rulers |
| `⌘⌃F` | Full screen |
| `⌘1` … `⌘9` | Jump to page 1…9 in current notebook |
| `⌥Space` | Global quick capture (v1.1) |

Rebindable through a v1.1 Settings pane; v1 ships the canonical
set above.

### 6.8 Onboarding

- **First launch.** A single-window sheet (no separate onboarding
  window):
  1. Welcome — "Cecilia's Notes syncs with your iPad through
     iCloud. Sign in to iCloud to get started."
  2. iCloud check — if signed in, one-line confirmation and a
     "Continue" button. If not, deep link to System Settings.
  3. Import (optional) — "Have a PDF you want to start with?
     Drag it here or click Choose…". Skippable.
  4. Done.
- **Subsequent launches.** Straight to the library. If the
  CloudKit container is still doing its first sync, show the
  library skeleton with a subtle progress bar in the sidebar
  header.

### 6.9 Empty states

- Empty library (no notebooks yet):
  - Centred illustration + "Create your first notebook" button +
    "or drag a PDF here".
  - Explicit "Open on your iPad" hint if the account is signed
    into iCloud but no notebooks have arrived yet — often the
    user's first notebooks are on iPad, and we want them to
    wait a moment for sync rather than create a duplicate on
    Mac.
- Empty notebook (no pages yet) — should never happen (notebook
  creation always creates a first page) but if a sync race
  produces one, we show a single "Add a page" button.

### 6.10 Error states

- **iCloud unavailable** — persistent yellow banner across the
  top of the library, "Not signed in to iCloud — your notes
  won't sync." Tap → System Settings deep link. Same string as
  iOS.
- **CloudKit stuck** — the dirty-launch streak auto-fallback
  from iOS carries over; after two consecutive dirty shutdowns
  the container opens local-only and a banner surfaces:
  "Sync is temporarily disabled. Toggle it back on in Settings
  → iCloud when you're ready."
- **Failed export** — inline alert with the error message,
  never a modal that blocks the window.
- **Broken media file** — placeholder tile with a "This file
  couldn't be opened" chip; the underlying `PageElement` is
  never deleted (matches iOS `AudioElementView` behaviour on
  corrupted `.m4a` files).

---

## 7. Universal search

- **Trigger.** `⌘⇧F` anywhere in the app. Also a magnifying-glass
  toolbar item.
- **Presentation.** Spotlight-style floating panel (not a sheet)
  centred on the current window's screen. Escape dismisses.
- **Index sources** (all live on iOS today via `SearchIndexService`):
  - Typed text elements.
  - OCR'd handwriting (Vision results cached on the `PageElement`).
  - PDF text layers.
  - Image alt-text (from Vision).
  - Quiz question / answer text.
  - Notebook titles, subject/folder names.
- **Ranking.** Exact match > phrase match > partial. Recency
  boost via `Page.updatedAt`. Subject-scoped queries filter first,
  rank second.
- **Result row** shows: subject chip + notebook cover + page
  thumbnail + surrounding context + timestamp. Enter opens the
  page in the current window, `⌘Enter` opens in a new window.
- **Live-updating.** Search runs on every keystroke against the
  in-memory index. First 200ms uses a debounced fetch; after that
  results stream in.

---

## 8. Handoff and continuity

### 8.1 iPad ↔ Mac page-level handoff

- **Mechanism.** `NSUserActivity` published by the currently-
  visible page.
- **Payload.**
  ```
  activityType: "app.ceciliasnotes.page"
  userInfo:
    notebookId: UUID
    pageId: UUID
    scrollOffset: CGFloat (normalised 0…1)
    zoom: CGFloat (0.25…4.0)
  requiredUserInfoKeys: [notebookId, pageId]
  ```
- **iPad side.** Existing `EditorView` already publishes a page-
  scoped `NSUserActivity`; we extend the payload to include
  scroll offset and zoom in the same commit that adds Mac support.
- **Mac side.** `NSApplicationDelegate.application(_:continue:...)`
  routes the activity to `WindowController.openNotebook(id:page:offset:zoom:)`.
- **Round-trip.** A user reading a page on Mac and picking up
  the iPad sees a Handoff icon in the iPad Dock; tapping it
  opens the same page. Vice versa the same way.

### 8.2 Universal Clipboard

- Automatic via AppKit — no code. Text, images, and PDFs
  copied on iPad paste on Mac as their native element types
  (via the `NSPasteboardItem` decoders we install).

### 8.3 Multipeer nearby-device sync

- Existing iOS ↔ iOS protocol (see `MULTIPEER_SYNC_PROTOCOL.md`)
  extends to include Mac in v1.1. The protocol is
  hardware-neutral — the discovery layer changes from
  `MCNearbyServiceBrowser` (present on macOS) to include Mac
  as both browser and advertiser.
- Not a v1 blocker. iCloud sync is the primary channel.

---

## 9. Export and print

- **Export dialog.** Sheet with:
  - Format: PDF (default) / Images (PNG bundle) / Markdown bundle
    (`.zip` with `.md` + `assets/`).
  - Scope: Whole notebook / Selected pages / Current page.
  - Options: Include page numbers, include audio transcripts,
    embed original PDFs.
  - Destination: Save Panel (default Downloads).
- **Print.** `NSPrintOperation` on the same rendered pages
  the PDF exporter produces. One page per sheet by default;
  user can pick 2-up / 4-up in the standard print sheet.
- **Share.** `NSSharingServicePicker` on the toolbar item;
  seeds with the current page as PDF unless a multi-page
  selection is active.

---

## 10. Settings

- **Native Settings window** (`NSApp.settingsWindow`). Toolbar
  along the top with these panes:
  1. **General** — appearance (system / light / dark), open at
     login toggle, "Show recent notebooks in the sidebar"
     toggle.
  2. **Library** — default cover style, default template, library
     home layout (grid / list), recents count.
  3. **iCloud** — account status, "Disable database sync
     (advanced)" toggle (mirrors iOS), sync-log link.
  4. **Editor** — default zoom (100 % / fit), scroll direction
     (natural / inverted), page-strip side (bottom / right), font
     defaults for text elements.
  5. **Export** — default format, default destination, embed
     audio transcripts by default (yes / no), auto-open exported
     file (yes / no).
  6. **Keyboard** — read-only in v1 (canonical list from §6.7).
     Editable in v1.1.
  7. **About** — version, build, "View release notes", "Contact
     support", "Privacy Policy", "Open Source Licences".
- **Preference persistence.** UserDefaults under the shared App
  Group so iPad and Mac see one another's changes where relevant.

---

## 11. Performance targets

Measured on the reference hardware (MacBook Air M2, 8 GB, 2022).

| Metric | Target |
|---|---|
| Cold launch (library) | < 800 ms to interactive |
| Open a 20-page notebook | < 500 ms to first page visible |
| Scroll a 200-page notebook at 60 Hz | 0 dropped frames |
| Universal search across 5 000 pages | < 300 ms to first result |
| Import a 100 MB PDF | < 3 s to page 1 rendered |
| Export 200 pages to PDF | < 10 s |
| Memory (200-page notebook open, idle) | < 400 MB resident |

Non-target: matching iPad benchmarks. iPad benefits from PencilKit
being the render path; Mac uses image-baked strokes and pays a
one-time decode cost.

---

## 12. Accessibility

- Full VoiceOver labels on every custom control. `NSAccessibility`
  protocols on custom views.
- **Font scaling** honours the user's system preference; nothing
  in the editor is baked to a fixed point size.
- **Increased Contrast** and **Reduce Transparency** are honoured
  via `NSAppearance` change notifications.
- **Reduce Motion** disables the cover-art shine animation and
  the page-strip parallax.
- **Full Keyboard Access** — every action is reachable without
  the pointer. Tab order goes sidebar → notebook list → editor →
  toolbar.
- **Voice Control** — command IDs published on every menu item
  (macOS does this automatically; we ensure our custom
  controls have `accessibilityLabel`s).

---

## 13. Privacy

- **No third-party dependencies.** No analytics SDK, no
  crash reporter, no third-party fonts, no telemetry endpoint.
- **No network calls** outside CloudKit sync (which is a
  first-party channel to the user's own iCloud account).
- **Microphone / camera** — deferred to v1.1 and gated behind
  their own consent flows.
- **Privacy manifest** (`PrivacyInfo.xcprivacy`) declares only
  the required-reason APIs the app uses (file timestamps,
  user defaults, disk space). No data collection declarations.
- **App Store nutrition label** — "Data Not Collected".

---

## 14. Rollout plan

### 14.1 Milestones

**M0 — Core extraction (week 1).** Move shared code out of the
iOS target into `CeciliasNotesCore` Swift package. iOS still
compiles + tests green.

**M1 — Skeleton (weeks 2–3).** Empty Mac target with the three-
pane window, sidebar populated from CloudKit, notebook list
grid, editor pane placeholder. Read-only. Universal Purchase
wired up.

**M2 — Read fidelity (weeks 4–5).** All element types render.
Strokes rasterised. Zoom / pan / scroll working. Handoff from
iPad opens the same page.

**M3 — Editing (weeks 6–7).** Text-element edit, insert / delete
elements, drag-and-drop import, undo / redo. Multi-select in
sidebar. Search working. Toolbar polished.

**M4 — Export + settings (week 8).** Export dialog, print, share.
Settings window complete. Onboarding sheet. Error / empty
states.

**M5 — Beta (week 9).** TestFlight to internal + close users.
Ten-user private test.

**M6 — Ship (week 10).** Mac App Store submission. Universal
Purchase live.

### 14.2 Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| CloudKit sync races between Mac and iPad on the same account | Medium | Existing last-write-wins model handles this; regression tests in Core exercise the iPad→Mac→iPad triangle. |
| Stroke rasterisation looks blurry at high zoom | Medium | Render at `2×` the current zoom scale factor and cache per zoom bucket; revisit vector path in v1.2. |
| PDF rendering memory spikes on large decks | Low | `PDFDocument` per notebook, shared across pages; unload the doc when the notebook window closes. |
| Sandbox blocks a legit import path | Low | All import goes through `NSOpenPanel` / drag-drop, both of which mint valid bookmarks. |
| Users try to draw on Mac and expect it to work | High | UX copy on the empty toolbar tools slot: "Handwriting is iPad-only." + docs. |
| Universal Purchase mis-config drops installs | Low | Follow Apple's checklist; test with a fresh App Store account before submission. |
| First-launch sync races the library render, showing an empty state momentarily | Medium | Skeleton loader in the sidebar during first fetch; empty-library copy explicitly mentions iPad. |

### 14.3 Feature-flag gating

- Every M2+ surface hides behind a Growthbook-style local
  UserDefaults flag until QA signs off. Flags default off in
  Release, on in Debug, controlled via a hidden **⌥-click on
  "About"** debug menu.

---

## 15. Open questions (for the implementing LLM to flag if hit)

- **Rich-text schema alignment.** iOS `TextContent` may or may
  not carry an `NSAttributedString`-compatible representation
  today; if not, define one in Core before M3 and migrate the
  iOS text-element renderer to consume it — otherwise Mac edits
  will visually diverge on iPad.
- **Pointer-vs-touch handles.** The iPad element handles are
  sized for touch (44 pt hit targets). Mac needs smaller
  handles (10–14 pt). Decide whether to add a `PointerContext`
  parameter to shared handle views or fork the view at the
  target boundary.
- **Zoom behaviour under trackpad-vs-mouse.** Pinch is obvious;
  mouse-wheel + `⌥` zoom feels natural to some users but not
  all. Ship both, with a Settings toggle for the mouse-wheel
  variant if user feedback pushes back.
- **Handoff scroll offset precision.** The normalised (0…1)
  offset may not survive a page-size change if the notebook was
  re-templated between publish and receive. Fall back to
  page-level handoff (no offset) if the receiver's page dimensions
  don't match the publisher's.
- **Notebook-level windowing under multi-monitor.** A user may
  drag two notebooks onto two monitors and expect independent
  zoom / scroll. The window-per-notebook model in §6.1 supports
  this; verify no shared editor singletons leak.

---

## 16. Definitions

- **Notebook.** A single `Notebook` model row with N `Page`
  children. Roughly analogous to a `.pages` document, but never
  surfaced to Finder.
- **Page.** A single `Page` model row with N `PageElement`
  children. Fixed logical page size (A4 default); actual pixel
  size is a function of zoom.
- **PageElement.** The unified V6 element type covering strokes,
  text, images, PDF-page references, shapes, sticky notes, audio.
  See ARCHITECTURE.md §"Unified PageElement model".
- **Subject / Folder.** Organisational parents for notebooks.
  Depth ≤ 3 (subject → folder → notebook).
- **Universal Search.** The Spotlight-style global search
  described in §7. Distinct from find-in-current-notebook
  (`⌘F`).
- **Handoff.** Apple's `NSUserActivity`-based device-to-device
  hand-off. Not to be confused with the multipeer
  nearby-sync protocol.

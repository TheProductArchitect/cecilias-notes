# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Ink** — local-first iPad note-taking app. Swift/SwiftUI, targeting iOS/iPadOS 17+. No backend, no accounts. All data stored on-device via SwiftData; optional iCloud Drive sync mirrors the Notebooks asset directory only (the SQLite store stays local).

## Build & Test

This is a pure Swift package / Xcode project. There is no `package.json`, no Makefile, and no `xcodebuild` wrapper script yet — commands below assume Xcode or Swift Package Manager CLI.

```bash
# Build (simulator)
xcodebuild -scheme Ink -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' build

# Run all unit tests
xcodebuild test -scheme Ink -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'

# Run a single test class
xcodebuild test -scheme Ink -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:InkTests/StorageServiceTests

# Run a single test method
xcodebuild test -scheme Ink -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)' \
  -only-testing:InkTests/StorageServiceTests/test_deletePage_renumbers_subsequent_pages
```

## Architecture

### Data flow

```
InkApp (root)
  └── environmentObject: ThemeManager   — theme state + UIWindow overrideUserInterfaceStyle
  └── environmentObject: StorageService — singleton, all SwiftData reads/writes
  └── environmentObject: CloudSyncManager — iCloud Drive mirroring state
```

Views never touch `ModelContext` directly. All persistence goes through `StorageService`.

### Persistence layer

**SwiftData** schema: `Subject → [Notebook] → [Page] → [TextBlock, MediaAttachment, AudioAnnotation]`. All relationships are `deleteRule: .cascade`.

**Two-tier storage:**
- `Application Support/Ink/ink.sqlite` — SwiftData store (local only, never synced)
- `Application Support/Ink/Notebooks/{notebookId}/media/`, `/audio/`, `/exports/` — binary assets (iCloud Drive-eligible)

`MediaAttachment` and `AudioAnnotation` both carry a denormalised `notebookId: UUID` so file URL construction (`mediaURL(for:)`, `audioURL(for:)`) is synchronous without an extra context fetch.

**Soft-delete contract:** Every model has `isDeleted: Bool` and `deletedAt: Date?`. `StorageService` filters these in every fetch. Physical deletion only via `emptyTrash()` or `purgeExpiredDeletedRecords()` (30-day cutoff). Never call `context.delete()` directly from feature code.

**`updatedAt` auto-bump:** Every mutable stored property on every model carries `willSet { updatedAt = Date() }`. StorageService also sets `updatedAt` explicitly in each mutation method as a safety net (SwiftData's `@Model` macro rewrites properties as computed accessors; observer preservation is iOS 17-dependent).

**Testing:** `ModelContainer.inkTestContainer()` returns an in-memory container. `StorageService(container:)` accepts an injected container — all unit tests use this path. The singleton `StorageService.shared` uses the disk-backed production container.

### Design system

All tokens live in `DesignSystem/` and are consumed as Swift extensions — never hardcoded values in feature code.

| File | What it owns |
|---|---|
| `InkColors.swift` | `UIColor` dynamic-provider tokens + `Color` bridge. Use `UIColor` variants in UIKit/PencilKit contexts, `Color` variants in SwiftUI. |
| `InkTypography.swift` | `Font` + `UIFont` extensions. 10 named tokens (`.inkDisplay` → `.inkMono`). |
| `InkSpacing.swift` | `Ink.Spacing.*` and `Ink.Radius.*` as `CGFloat` constants. |
| `InkAnimations.swift` | `InkSpring.*` presets + `.inkAnimation(_:value:)` modifier. All animations must go through these — they automatically fall back to crossfade when Reduce Motion is on. |
| `InkComponents.swift` | `InkButton`, `InkTextField`, `.inkCard()`, `InkBadge`, `InkDivider`, `InkEmptyState`. |
| `ThemeManager.swift` | `InkTheme` enum + `ThemeManager` (`@AppStorage`-backed, applies via `UIWindow.overrideUserInterfaceStyle` on all connected scenes). |

### Visual rules (enforced everywhere, not just in the design system)

- **Shadows:** forbidden except one — the page boundary in the editor (`CALayer` shadow: offset `0,1`, radius `4`, opacity `0.08`, colour black).
- **Borders:** always `0.5pt` hairlines. The sole exception is the 2pt accent ring on the selected theme card in Settings.
- **Animations:** always spring-based via `InkSpring.*`. Linear and easing animations are prohibited.
- **Icons:** SF Symbols only, weight `.medium`. No custom image assets.
- **Backdrop blur:** used in exactly one place — the editor toolbar (`UIVisualEffectView` with `.systemUltraThinMaterial`).

### Style guide

`Features/Settings/StyleGuideView.swift` is a living catalogue of every token and component, compiled only in `DEBUG` builds. Accessible via 4-finger tap on `RootView` at any time.

### iCloud sync

`CloudSyncManager` mirrors `Application Support/Ink/Notebooks/` into the iCloud ubiquity container's `Documents/Notebooks/` directory using `NSFileManager.setUbiquitous(_:itemAt:destinationURL:)`. `NSMetadataQuery` tracks per-file upload/download progress. The SwiftData SQLite file is intentionally excluded from sync. `isEnabled` is persisted to `UserDefaults` under key `ink.icloud.sync.enabled`.

### Library (Stage 3)

`Features/Library/` is the app's home screen. Entry point: `LibraryView` → `RootView` → `InkApp`.

**ViewModel pattern:** `LibraryViewModel` is the single source of truth for all Library state. Views are purely declarative — no direct `StorageService` calls from any view. After every mutation the ViewModel calls `refresh()` to re-fetch from `StorageService`.

```
LibraryView  (NavigationSplitView, sidebar never collapses)
  ├── SubjectSidebarView          260pt fixed sidebar
  │   ├── AllNotesRow             always first, not reorderable
  │   ├── SubjectRowView          inline rename (double-tap), context menu, drop target
  │   │   └── SubjectColourPickerView   4×3 colour grid popover
  │   └── iCloudStatusView        bottom-left cloud indicator
  └── NotebookGridView            detail column
      ├── GridToolbarView         custom HStack (not NavigationView toolbar)
      ├── PinnedNotebooksStrip    horizontal scroll, 140×168pt cards, shown if any pinned
      ├── LazyVGrid               adaptive min 168pt columns, 16pt spacing, 24pt padding
      │   └── NotebookCardView    168×200pt, 60/40 cover/info split
      │       └── CoverTextureCanvas   programmatic Canvas, white 8% opacity strokes
      ├── SearchResultsView       replaces grid when isSearchActive, grouped sections
      └── NewNotebookSheet        .medium detent, autofocused title, all notebook options
```

**Key ViewModel state:**
- `selectedSubjectId: UUID?` — nil = All Notes
- `isSearchActive: Bool` — drives search bar slide-in and grid/results swap
- `searchText: String` — debounced 250 ms via Combine `$searchText.debounce`
- `duplicatingIds: Set<UUID>` — which cards show a loading spinner overlay
- `renamingSubjectId: UUID?` — signals `SubjectRowView` to enter inline rename mode

**Card cover textures** are drawn in `CoverTextureCanvas` using SwiftUI `Canvas`. No image assets. White strokes at 8% opacity. `CoverTexturePreview` is a 52×52pt version for the `NewNotebookSheet` picker.

**Drag and drop:**
- `NotebookCardView` is `.draggable` with a JSON-encoded `NotebookTransferID`
- `SubjectRowView` and `AllNotesRow` are `.dropDestination` targets — decode `NotebookTransferID` and call `viewModel.moveNotebook(id:to:)`
- Grid reorder (manual sort only) uses `.draggable` with a ghost preview at 60% opacity

**Animations:** all card transitions use `.scale(scale: 0.85).combined(with: .opacity)`. Multi-select checkboxes spring in via `.transition(.scale.combined(with: .opacity))`. All `withAnimation` calls use `InkSpring.smooth` or `InkSpring.snappy`.

### Editor (Stage 4) — pencil latency is paramount

`Features/Editor/` is the heart of the app. Presented as a **full-screen modal** over the Library (not a `NavigationSplitView`). Entry point: `EditorView`, presented as `.fullScreenCover` when `LibraryViewModel.editingNotebook` is non-nil.

```
EditorView  (ZStack — pure SwiftUI shell over a UIKit canvas)
  ├── CanvasContainerView         UIViewRepresentable: UIScrollView → PageRenderer + PKCanvasView
  │   └── Coordinator             UIScrollViewDelegate, PKCanvasViewDelegate, UIPencilInteractionDelegate
  ├── PageRenderer                UIView, draws page background + template via Core Graphics
  ├── EditorToolbarView           top 52pt — blur background, auto-hides after 3.5s
  │   └── SaveStatusIndicator     cloud / checkmark / exclamationmark, fades 1s on success
  ├── ToolPaletteView             floating draggable pill, position persisted to UserDefaults
  │   └── ColorPickerView         popover: Recent / Presets / Custom / Opacity
  ├── PageStripView               bottom slide-in strip, 80×104pt thumbnails (NSCache)
  └── MinimapView                 floating bottom-right when zoom > 150%
```

**Pencil/finger separation — non-negotiable foundation:**
- `canvasView.drawingPolicy = .pencilOnly` — finger never draws.
- `canvasView.isScrollEnabled = false` — the wrapping `UIScrollView` handles pan/pinch.
- `scrollView.delegate = coordinator`, `viewForZooming` returns the content view that contains both `PageRenderer` and `PKCanvasView` (they zoom together).
- `UIPencilInteraction` added to `canvasView` for pencil double-tap actions.

**Page swap path — must complete in < 50ms (loading indicator only over 100ms):**
1. Save current: `canvasView.drawing` → `dataRepresentation()` → `StorageService.updatePageStrokes`
2. Load next: deserialise `strokeData` → `PKDrawing(data:)` → `canvasView.drawing = newDrawing`
3. **Never recreate `PKCanvasView`** — only swap the `drawing` property. PencilKit's metal-backed renderer takes time to spin up; the cost is paid once per editor session.

**Autosave — never block the drawing thread:**
- `canvasViewDrawingDidChange` cancels the existing save task and schedules a new one 1.2s later (`Task.sleep`).
- Save serialises and persists on the main actor (fast). Thumbnail regeneration is dispatched to a `Task.detached(priority: .utility)`.
- `saveStatus: SaveStatus` published state drives the indicator: `.idle → .saving → .saved (1s fade) → .idle` or `.error (persists)`.

**Tool palette state** lives in `EditorViewModel.selectedTool: InkTool`. The `InkTool` enum has associated values (colour, width, opacity per case). Mapping to `PKTool` happens once per change in `CanvasContainerView.updateUIView` — the resulting `PKInkingTool` / `PKEraserTool` / `PKLassoTool` is set on `canvasView.tool`. Ruler is `canvasView.isRulerActive`.

**Tool palette position** persisted to `UserDefaults` under `ink.toolPalette.position` as a `CGPoint` (encoded). Default: right edge, vertically centred.

**Recent colours** persisted as a `[String]` of hex values under `ink.colorPicker.recent`. Capped at 8, deduplicated, most-recent-first.

**Page background rendering** — `PageRenderer` is a `UIView` subclass that draws the template via Core Graphics (`override func draw(_ rect:)`). Never via PencilKit. Page shadow is applied to the renderer's `layer` (offset `0,1`, radius `4`, opacity `0.08`). This is the **second of only two** shadow exceptions in the entire app.

**Toolbar auto-hide:**
- `EditorViewModel.resetToolbarTimer()` sets `isToolbarVisible = true` and schedules a 3.5s `Task` that flips it to false on completion.
- Any touch in the top 60pt of the screen calls `resetToolbarTimer()`.
- Toolbar fades via opacity (`isToolbarVisible ? 1 : 0`) — never structurally removed from the hierarchy.

**Page strip thumbnails:**
- `PageThumbnailCache` is a singleton `NSCache<NSUUID, UIImage>` keyed by `Page.id`.
- Thumbnails generated via `PKDrawing.image(from:scale:)` on a `Task.detached(priority: .utility)`.
- Cache invalidated for the current page on every save.

**Minimap:**
- Visible only when `viewModel.zoomScale > 1.5`.
- Renders the page thumbnail behind a translucent rectangle representing the visible viewport.
- Updates throttled to 15fps via a `Timer`/`Task.sleep` loop — never on the drawing thread.
- Drag rectangle to pan; tap to centre.

### Text blocks (Stage 5) — TextKit 2 + gesture routing

`Features/Editor/TextBlocks/` contains the entire text layer.

```
EditorView
  └── CanvasContainerView (UIViewRepresentable)
      └── contentView (UIView, page coordinate space)
          ├── PageRenderer
          ├── PKCanvasView  (drawingPolicy = .pencilOnly, finger never draws)
          ├── TextBlockOverlayView (UIHostingController host, SwiftUI)
          │   ├── Color.clear  (creates blocks on tap in text mode)
          │   └── Per-block VStack
          │       ├── TextBlockView  (UIViewRepresentable → InkTextView)
          │       │   └── RichTextToolbar  (inputAccessoryView, 44pt)
          │       └── ResizeHandlesView  (8 handles, .selected state only)
          └── TextModeGestureController  (transparent UIView, hitTest gate)
```

**The critical routing invariant — enforced by `TextModeGestureController.hitTest`:**
- Stylus touches (`.type == .stylus`) always return `nil` → fall through to `PKCanvasView`.
- In text mode + finger: routes to `TextBlockOverlayView` (which has `isUserInteractionEnabled = true`).
- Not in text mode + finger: returns `nil` → `UIScrollView` handles pan/pinch as before.

**Text block interaction state machine (`TextBlockInteractionState`):**
- `.idle` → finger tap → `.selected` (shows resize handles)
- `.selected` → finger tap → `.editing` (keyboard appears, `textView.isEditable = true`)
- `.editing` → Escape or toolbar dismiss → `.idle`
- Tapping outside any block calls `deselectAll()` → all blocks back to `.idle`

**InkTextView** (UITextView subclass) adds `UIKeyCommand` for Cmd+B/I/U/K and Escape without putting the coordinator in the responder chain.

**RichTextAttributes** — all attribute toggles. Pure functions on `NSMutableAttributedString`. Supports: bold, italic, underline, H1/H2/H3, bullet list, inline code, blockquote, hyperlink. Each toggle queries current state and flips it — no separate "is active" tracking needed at the call site.

**MarkdownShortcutHandler** — called from `textView(_:shouldChangeTextIn:replacementText:)`. Matches typing patterns backwards from cursor on Space or Enter: `#`/`##`/`###` → headings, `**`/`_` → bold/italic, `-`/`*` → bullet, `>` → blockquote. Returns `false` to consume the triggering keystroke; mutates `attributedText` directly.

**Block creation:** finger tap on empty canvas in text mode creates a `TextBlock` via `StorageService.createTextBlock` at normalised coordinates, then immediately enters `.editing` state. Default size: 200×60pt.

**Layout persistence:** block positions are stored normalised (0.0–1.0 of page dimensions). During drag/resize the normalised rect is updated in-memory (`layouts` state dict). On gesture end, `StorageService.updateTextBlock(block:richText:rect:)` commits to SwiftData.

**Keyboard management:** `EditorView` subscribes to `keyboardWillShowNotification` / `keyboardWillHideNotification`. Height is published via `EditorViewModel.keyboardVisibleHeight`. Toolbar and Page Strip clear this area automatically when visible.

**Save debounce:** every keystroke schedules a 2s `Task.sleep` (cancelling the prior task). On keyboard dismiss, `commitNow()` fires immediately.

### Media attachments (Stage 6)

`Features/Editor/Media/` contains the full image insertion and manipulation pipeline.

```
EditorView
  └── CanvasContainerView
      └── contentView
          ├── PageRenderer
          ├── PKCanvasView
          ├── MediaAttachmentOverlayView  ← Z-order below text blocks
          ├── TextBlockOverlayView
          └── ContentLayerGestureController  ← replaces Stage 5's TextModeGestureController
```

**Four insertion paths** (all routed through `MediaInsertCoordinator`):
- Photos Library: `PHPickerViewController`, multi-select, max 10
- Files: `UIDocumentPickerViewController`, .image + .pdf types
- Camera: `UIImagePickerController` (.camera source)
- Scan: `VNDocumentCameraViewController`

**`ImageProcessingService` (actor)** — runs fully off the main thread:
1. Decode: HEIC/JPEG/PNG/WebP/GIF (first frame via ImageIO)
2. Orient: apply EXIF orientation via `UIGraphicsImageRenderer`
3. Scale: longest edge > 4096px → downscale preserving aspect
4. Compress: JPEG 88% to `media/{id}.jpg`
5. Thumbnail: 400pt max, JPEG 75% to `media/{id}_thumb.jpg`

**`MediaAttachmentView`**: thumbnail for display width < 800pt, full-res async otherwise. Thumbnail shown as placeholder during full-res load.

**`MediaAttachmentOverlayView`**: SwiftUI ZStack rendering all attachments sorted by `zIndex`. Gesture routing: interactive only when `selectedTool.isMediaInteractive` (i.e., not pen/pencil/highlighter).

**Transform system:**
- Move: drag inside image (not on handle)
- Scale: 8 handles (corners = proportional, edges = single-axis)
- Rotate: 28pt accent circle above top-centre handle; live angle label
- Snap guides: 1pt lines at page centre at 40% opacity when within 4pt
- Feedback labels: "32°" during rotation, "340 × 220 pt" during scale

**`ContentLayerGestureController`** (upgraded from `TextModeGestureController`):
Pencil → always nil; finger in text mode → textOverlay; finger in non-drawing mode → mediaOverlay; else → nil (scroll).

**`InlineCropView`**: full-screen sheet with `CropCanvasUIView` (custom UIView + CALayer `.evenOdd` fill for the dimmed overlay). Aspect lock options: Free/1:1/4:3/16:9/A4/Letter. Rotate 90° CW/CCW. Done creates a new JPEG and replaces the file.

**PDF insertion**: each page rasterised at 150dpi via `ImageProcessingService.rasterisePDFPage`. Page 1 → current page; pages 2+ → new notebook pages. Progress HUD during rasterisation.

**Multi-image insert**: `TaskGroup` parallel processing. First image centred; each subsequent +16pt cascade. All inserted images start selected (`viewModel.selectedAttachmentIds`).

**Undo (session-only)**: `deleteAttachment` registers in `EditorViewModel.deletedAttachmentsUndo`. `undoLastAttachmentDelete()` calls `StorageService.restoreAttachment` (flips `isDeleted = false`).

**`MediaAttachment` model additions (Stage 6):** `opacity: Double` (0.2–1.0, default 1.0). `StorageService` additions: `updateAttachmentZIndex`, `replaceAttachmentImage`, `restoreAttachment`, `addPreprocessedImage`.

### Audio annotations (Stage 7)

`Features/Editor/Audio/` contains the complete audio recording, playback, and transcription pipeline.

```
EditorView
  └── CanvasContainerView
      └── contentView
          ├── PageRenderer
          ├── PKCanvasView
          ├── MediaAttachmentOverlayView
          ├── TextBlockOverlayView
          ├── AudioAnnotationPinsOverlayView  ← always interactive (finger + pencil-adjacent)
          └── ContentLayerGestureController  ← audioOverlay always routed, regardless of tool
  ├── RecordingPanelView  ← 180pt bottom overlay in EditorView ZStack (NOT a sheet)
  └── AudioPlayerView     ← 320×280pt popover anchored to tapped pin
```

**Critical invariant — 100% on-device, zero network calls:**
- `SFSpeechRecognizer` is used with `requiresOnDeviceRecognition = true` on every `SFSpeechAudioBufferRecognitionRequest`.
- `supportsOnDeviceRecognition` is checked before starting any recognition. If false, transcription is silently skipped — `isTranscribed` stays `false`.
- Any code path that allows a network call for audio processing is a critical bug.

**`AudioRecorder` (actor)**:
- `AVAudioEngine` with a PCM tap (1024-frame buffer, 44.1kHz mono `Float32`) for both recording and live waveform.
- `AVAssetWriter` + `AVAssetWriterInputMetadataAdaptor` → AAC 128kbps M4A output.
- `vDSP_rmsqv` (Accelerate) computes per-buffer RMS; published as `AsyncStream<Float>` for waveform.
- Microphone permission checked via `AVAudioApplication.requestRecordPermission(completionHandler:)`.
- Output file: `audio/{notebookId}/{annotationId}.m4a` (directory created on first use).
- `finishRecording() async throws -> (duration: Double, fileSizeBytes: Int64)`.

**`SpeechTranscriber` (actor)**:
- `SFSpeechRecognizer(locale: .current)` — falls back to `en-US` if current locale lacks on-device model.
- `SFSpeechAudioBufferRecognitionRequest` with `requiresOnDeviceRecognition = true`.
- Same PCM buffers from `AVAudioEngine` tap are appended to the recognition request.
- Emits `AsyncStream<String>` of partial hypotheses; final result is word-segmented into `[TranscriptionSegment]`.
- `TranscriptionSegment.word/startTime/endTime/confidence` derived from `SFTranscriptionSegment`.

**`WaveformView` (SwiftUI Canvas)**:
- Live mode: 2.5pt-wide bars, animated at 20fps via `TimelineView(.animation(minimumInterval: 0.05))`.
- Static mode (playback): fixed bars pre-computed from `AudioAnnotation.amplitudeData` (RMS per 50ms window).
- Bar height: log scale, 4pt minimum, 60pt maximum; `vDSP_rmsqv` result mapped logarithmically.
- Playhead line splits bar colour: accent tint left, tertiary right.
- Bars slide in from right during live recording (ring-buffer of last N samples).

**`RecordingPanelView`**:
- 180pt bottom overlay (not a sheet — slides up from bottom of `EditorView` ZStack).
- States: `.idle` (mic button), `.recording` (waveform + timer + stop), `.processing` (spinner).
- Transcription toggle — shown during recording; hides if `SFSpeechRecognizer.supportsOnDeviceRecognition` is false.
- On stop: calls `AudioRecorder.finishRecording()`, then `StorageService.addAudioAnnotation`, then dispatches `SpeechTranscriber.transcribe(url:annotation:)` as a detached background task.

**`AudioAnnotationPinsOverlayView`**:
- SwiftUI ZStack, always `isUserInteractionEnabled = true` (independent of tool selection).
- Renders one `AudioAnnotationPinView` per non-deleted annotation on the current page.
- Pin position: `annotation.pageX * pageSize.width`, `annotation.pageY * pageSize.height`.
- Long-press or drag to reposition pin (normalised position written to `StorageService`).

**`AudioAnnotationPinView`**:
- 32pt circle, SF Symbol `waveform` inside.
- Idle: `inkAccent` fill, white icon.
- Playing: pulsing ring animation (`scale(1.4)` + `opacity(0)` loop at 1.2s) — one `InkSpring.smooth` loop.
- Tap → shows `AudioPlayerView` as a `.popover`.

**`AudioPlayerView` (popover, 320×280pt)**:
- `AVAudioPlayer` for playback (not AVAudioEngine).
- `WaveformView` in static mode with playhead scrubbing.
- Word-level transcript highlight — scrolls `Text` runs; highlighted word has `inkAccent` background.
- Speed controls: 0.5×, 1×, 1.5×, 2× via `AVAudioPlayer.rate` (`enableRate = true`).
- `TranscriptionSegment` array decoded from `annotation.transcriptionSegments` (JSON).

**`AudioFilePicker`**:
- `UIDocumentPickerViewController` for `.audio` + `.m4a` + `.mp3` + `.wav` UTTypes.
- Selected file copied into `audio/{notebookId}/{newId}.m4a` (transcoded if not M4A via `AVAssetExportSession`).
- Inserts annotation via `StorageService.addAudioAnnotation` then triggers transcription.

**`AudioAnnotation` model additions (Stage 7):**
- `isTranscribed: Bool` (default `false`, set to `true` after successful `updateTranscription` call).
- `amplitudeData: Data?` — archived `[Float]` RMS values (one per 50ms), written by `SpeechTranscriber` after full-file pass. Used to render static waveform without re-reading the M4A.

**`StorageService` additions (Stage 7):**
- `insertAudioFile(to:sourceURL:at:) async throws -> AudioAnnotation` — copies file, creates record.
- `updateAmplitudeData(_:amplitudes:) throws` — writes archived `[Float]` to `amplitudeData`.

**`ContentLayerGestureController` update (Stage 7):**
- Added `weak var audioOverlay: UIView?`.
- Audio overlay always routes finger touches regardless of `isTextMode` or `isMediaInteractionEnabled` — checked first after the pencil guard, returning the hit view if non-nil.

**`EditorViewModel` additions (Stage 7):**
- `@Published var isRecordingPanelVisible: Bool = false`
- `@Published private(set) var currentPageAudioAnnotations: [AudioAnnotation] = []`
- `@Published var playingAnnotationId: UUID?`
- `refreshCurrentPageAudioAnnotations()` — called in `goToPage`, `refreshPages`.

### PDF export, printing & sharing (Stage 8)

`Features/Export/` contains the complete export pipeline.

```
LibraryView  (… menu → Recent Exports)
  └── RecentExportsView            half-height sheet, last 10 exports

EditorView
  └── ExportOptionsView            .medium sheet — options + live preview + export button
      └── ExportProgressView       replaces content within same sheet (no dismiss)
          ├── progress state       ring indicator + "3 / 12 pages"
          ├── success state        checkmark + Share + Save to Files buttons
          └── error state          exclamationmark + message + Try Again
```

**`ExportService` (actor)** — all work off the main thread:
- `ExportOptions`: `pageRange` (`.all` / `.current(Int)` / `.range(ClosedRange<Int>)`), `quality` (`.standard` 150dpi / `.high` 300dpi), `includeTranscriptions: Bool`, `includePageNumbers: Bool`, `includeCoverPage: Bool`
- `ExportResult`: `fileURL`, `fileSizeBytes`, `pageCount`, `duration`
- `exportNotebook(_:options:progress:) async throws -> ExportResult`
- Output path: `Application Support/Ink/Exports/{title}_{yyyy-MM-dd}.pdf` — appends `_2`, `_3` on collision.

**PDF rendering pipeline** (one `UIGraphicsPDFRenderer` for all pages):
1. **Template background** — redrawn as Core Graphics vector paths (same logic as `PageRenderer`; not rasterised).
2. **Media attachments** — load from disk, draw at normalised rect × `pageBounds`; apply `CGAffineTransform(rotationAngle:)` + opacity.
3. **PencilKit strokes** — `PKDrawing.image(from:scale:)` at DPI scale (150/72 or 300/72); rasterised (PencilKit limitation).
4. **Text blocks** — rendered as actual PDF text via `NSAttributedString.draw(with:options:context:)`. PDF origin is bottom-left; Y is flipped: `pdfY = pageHeight − (normY × pageHeight) − blockHeight`. Text is searchable and copyable in Preview/Acrobat.
5. **Audio markers** — `includeTranscriptions`: microphone SF Symbol at pin position + horizontal rule + transcript in `.inkCaption` style as footnote.
6. **Page numbers** — `"\(index+1) / \(total)"` centred 16pt from bottom edge.

**Cover page** (if `includeCoverPage`): full page with `coverColorHex` background, cover texture overlay (same `CoverTextureCanvas` logic), notebook title in `.inkDisplay` centred, subject name in `.inkTitle2` `.inkTextSecondary`, export date in `.inkFootnote` `.inkTextTertiary`, "Ink" wordmark bottom-right in `.inkCaption` `.inkTextTertiary`.

**`ExportOptionsView`** (`.medium` detent sheet):
- **Page range**: segmented `[All][Current][Custom]`. Custom reveals text field (`"e.g. 1–5, 8, 12"`) with real-time validation (`.inkBorderDestructive` + error label for invalid input).
- **Quality**: segmented `[Standard][High]`. Sub-label shows `"~3.2 MB"` estimated size (page area × dpi² × 0.1 bytes/px).
- **Toggle list**: Include page numbers / Include cover page / Include audio transcripts.
- **Live preview**: first-page thumbnail generated async (`Task.detached`) while sheet is open; `ProgressView` placeholder until ready.
- **Export button**: primary, full-width — starts export, transitions sheet content to `ExportProgressView`.

**`ExportProgressView`** (replaces options content within the sheet — no dismiss):
- **Progress**: 80pt ring `ProgressView(value:)` with 4pt stroke, accent tint; `"Exporting… 3 / 12 pages"` `.inkBody`; Cancel button → `task.cancel()`.
- **Success** (crossfade): 60pt `checkmark.circle.fill` SF Symbol spring-in; file size + page count; "Share" (primary) + "Save to Files" (secondary).
- **Error**: `exclamationmark.circle` + message text + "Try Again" button.

**`ExportManifest`** — `Application Support/Ink/exports_manifest.json`:
- `[ExportRecord]` — `id`, `notebookId`, `notebookTitle`, `fileURL`, `fileSizeBytes`, `pageCount`, `exportedAt`.
- Max 10 records; oldest pruned automatically. `ExportManifest.shared` (actor) handles read/write.

**`RecentExportsView`** — half-height sheet from Library `…` menu:
- List of last 10 `ExportRecord`s: title + date + size + page count.
- Swipe to delete — removes file + record.
- Tap: presents `UIActivityViewController` with the PDF URL.
- Missing file: alert with "Re-export" option (re-presents `ExportOptionsView` for that notebook).

**Sharing**:
- "Share" → `UIActivityViewController(activityItems: [fileURL])`. No `applicationActivities` filter.
- "Save to Files" → `UIDocumentPickerViewController(forExporting: [fileURL])`.
- Print available via `UIActivityViewController`'s built-in Print activity AND via `UIPrintInteractionController.shared.present(animated:)` from the `…` More menu.

### Settings (Stage 9)

`Features/Settings/` is a full-screen sheet opened from the Library toolbar gear icon.

```
LibraryView  (gear toolbar button → fullScreenCover)
  └── SettingsView  (NavigationSplitView, 220pt sidebar + detail column)
      ├── Sidebar  (SettingsSection.allCases, List)
      └── Detail (section-specific view, driven by selectedSection)
          ├── AppearanceSettingsView   ThemePickerView (ForEach InkTheme.allCases)
          ├── PencilSettingsView       double-tap / pressure pills / smoothing slider / toggles
          ├── NewPagesSettingsView     page size / template horizontal scroll / auto-add
          ├── AudioSettingsView        locale picker sheet / auto-transcribe / quality
          ├── CloudSettingsView        iCloud card + sync status + usage async load
          ├── StorageSettingsView      3 metric cards + clear actions
          └── AboutSettingsView        version / keyboard shortcuts / privacy / feedback
```

**`SettingsViewModel` (`@MainActor ObservableObject`)** — owns `ThemeManager` and `CloudSyncManager` references, all `@AppStorage` values, and storage metrics computed async. Passed down to every section view as `@ObservedObject`.

**`SettingsSection` enum** — `allCases` drives both the sidebar list and the detail `switch`. Adding a section only requires a new case — no structural changes to `SettingsView`.

**`ThemePickerView`** — `ForEach(InkTheme.allCases)`. Adding a theme requires only a new `InkTheme` case with four preview colours; `ThemePickerView` gets the new card automatically.

**`ThemePreviewCard`** (160×200pt):
- Background: `theme.previewBackground`.
- Interior: simulated notebook card with text/accent bars.
- Three SwiftUI `Canvas` ink stroke curves (`curvePath(in:yFraction:amplitude:)` cubic Bezier).
- Selected state: 2pt `inkAccentPrimary` border + `checkmark.circle.fill` SF Symbol top-right.
- Tap: `ThemeManager.theme = theme` — takes effect immediately via `UIWindow.overrideUserInterfaceStyle`.

**Persisted keys (all `@AppStorage`):**

| Key | Type | Default |
|---|---|---|
| `ink.pencil.doubletap` | `DoubleTapAction` | `.switchTool` |
| `ink.pencil.pressure` | `PressureSetting` | `.medium` |
| `ink.pencil.smoothing` | `Double` | `50` |
| `ink.pencil.hoverPreview` | `Bool` | `true` |
| `ink.haptics.drawing` | `Bool` | `true` |
| `ink.newpage.size` | `PageSize` | `.a4` |
| `ink.newpage.autoAdd` | `Bool` | `true` |
| `ink.newpage.template` | `String` (JSON-encoded `PageTemplate`) | `"blank"` |
| `ink.transcription.locale` | `String` (locale identifier) | `""` (system) |
| `ink.transcription.auto` | `Bool` | `true` |
| `ink.transcription.quality` | `TranscriptionQuality` | `.fast` |

**Audio locale picker** — `LocalePickerSheet`: searchable list of `SFSpeechRecognizer.supportedLocales()` filtered to `supportsOnDeviceRecognition == true`. Network is never used at any point.

**iCloud card** — full-width `inkCard()` with: 28pt iCloud SF symbol + title + subtitle + `Toggle`. Toggle triggers confirmation alerts before any state change (`"Enable iCloud Sync?"` / `"Disable iCloud Sync?"`). Sync status rendered from `CloudSyncManager.syncStatus` — ProgressView (checking), ring+% (syncing), checkmark (upToDate), red (error + Retry). iCloud bytes computed async from ubiquity container on `.task`.

**Storage metrics** — three `metricCard` tiles (Total, Audio, Images) computed from `StorageService.localStorageUsed()` on `.task`. Clear actions have confirmation alerts; audio clear also calls `StorageService.clearAudioRecordings()` which soft-deletes all `AudioAnnotation` records + removes files.

**Pencil hover preview** — only shown if `UIDevice.current.userInterfaceIdiom == .pad` (checked via `SettingsViewModel.supportsHoverPreview`).

**Rate Ink** — `SKStoreReviewController.requestReview(in:)` called only if `notebookCount >= 3` AND the current version hasn't been asked before (persisted under `ink.review.requestedVersion`).

**`KeyboardShortcutsView`** — placeholder populated with common shortcuts; Stage 10 can add to this list without structural changes.

**`StorageService` additions (Stage 9):**
- `clearAudioRecordings() async throws` — removes `/audio/` directories + soft-deletes all `AudioAnnotation` records.
- `exportedPDFsSizeBytes() -> Int64` — directory size of `ExportService.globalExportsDirectory`.
- `audioSizeBytes() -> Int64` — sum of all per-notebook `/audio/` directories.
- `notebookCount() -> Int` — non-deleted notebook count (used by rate-app eligibility check).

### Polish, accessibility & App Store prep (Stage 10)

**`HapticManager` (singleton, `@MainActor`)** — `Core/Services/HapticManager.swift`. Wraps `UIImpactFeedbackGenerator` (light/medium/rigid), `UINotificationFeedbackGenerator`, `UISelectionFeedbackGenerator`. Generators are pre-warmed via `prepare()`. Two settings gates: `ink.haptics.drawing` (drawing-time) + `ink.haptics.ui` (UI-time), both default true. Rate-limited: minimum 80 ms between haptics (`lastFiredAt: Date`).

Named moments only — no raw generator usage anywhere else: `notebookCreated()`, `notebookDeleted()`, `pageAdded()`, `pageDeleted()`, `strokeBegins()` (gated on drawing flag), `toolSwitched()`, `exportCompleted()`, `exportFailed()`, `iCloudSyncCompleted()`, `contextMenuOpened()`, `dragReorderStarted()`, `dragReorderDropped()`, `destructiveConfirmed()`.

**`A11y` (Accessibility extensions)** — `Core/Extensions/AccessibilityExtensions.swift`. All accessibility label/hint strings live here as static computed strings (`A11y.notebookLabel(...)`, `A11y.canvasLabel(...)`, `A11y.toolLabel(...)`, `A11y.audioLabel(...)`, `A11y.mediaLabel(...)`). No literal accessibility strings appear in any view. `inkBorderWidth(base:)` and `inkSecondaryText()` View helpers respect `UIAccessibility.isDarkerSystemColorsEnabled` (high contrast). `inkTransition(_:)` collapses any transition to opacity-only when Reduce Motion is on.

**Animation rules:**
- Every `.linear` and `.easeInOut` audited and replaced with `InkSpring.*` (or `easeOut(duration: 1.2).repeatForever` for the audio-pin pulse, where exact loop timing is required).
- Tool-switch indicator: `matchedGeometryEffect(id: "activeToolIndicator", in: toolNamespace)` slides the 32pt accent circle between tools using `InkSpring.precise`.
- New / deleted notebook cards: `.scale(scale: 0.85).combined(with: .opacity)`.
- All `withAnimation(...)` calls go through `.inkSpring(...)` which auto-falls back to crossfade under Reduce Motion.

**Keyboard shortcuts** — registered via `.keyboardShortcut` in invisible-button stacks (`.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)`):
- **Library:** ⌘N (new notebook), ⌘F (search), ⌘, (settings).
- **Editor:** ⌘Z / ⌘⇧Z (undo/redo), ⌘E (export), ⌘P (print), ⌘← / ⌘→ (page nav), Esc (close), Space (toggle toolbar), 1–6 (tool switch), T (text tool).
- **Settings:** ⌘W or Esc (close).
- All shortcuts surfaced read-only in `KeyboardShortcutsView` (Settings → About → Keyboard Shortcuts).

**Spotlight** — `Core/Services/SpotlightService.swift` (actor). Identifier scheme: `"ink.notebook.{uuid}"` in domain `"ink.notebooks"`. `scheduleIndex(...)` debounces re-index calls 5 s after last save; `removeNotebook(id:)` is immediate on soft-delete.

`StorageService.scheduleSpotlightReindex(for:)` is called from `updateNotebook(...)`; `removeNotebook(id:)` from `deleteNotebook(...)`.

`InkApp` handles two launch paths into `DeepLinkRouter`:
- `.onContinueUserActivity(CSSearchableItemActionType)` — Spotlight tap.
- `.onOpenURL` — `ink://open/{uuid}`, `ink://library`, `ink://settings`.

`LibraryView` observes `DeepLinkRouter.openNotebookId` / `openSettings` and routes to the editor / settings sheet.

**Widgets** — `InkWidget/` (separate target). Two kinds:
- `LastOpenedNotebookWidget` (small): cover colour + texture + title + page count + "Ink" wordmark. `widgetURL` deep-links to `ink://open/{id}`.
- `RecentNotebooksWidget` (medium): small layout on the left + 3-row recent list on the right with `Link(destination:)` per row.

Data path: the main app writes `ink_widget_data.json` ([NotebookSummary]) to the App Group container after every notebook save (debounced 2 s via `WidgetDataWriter`). The widget reads via `WidgetDataWriter.read()` — no SwiftData dependency. Timeline reload every 15 minutes.

App Group: `group.com.ink.app` (change `WidgetDataWriter.appGroup` if your bundle id differs).

**App icon system** — `DesignSystem/InkIconRenderer.swift` + `Resources/AppIcon.svg` (master). Programmatic Core Graphics rendering from a 100×100 reference grid: ink-drop teardrop body forms the stem of a lowercase "i", accent circle above forms the dot. Three themes (`light`, `dark`, `tinted`); the tinted variant uses `.systemBackground`/`.label`/`.tintColor` for iOS 18+ system tinting. `IconPreviewView` (DEBUG, surfaced in `StyleGuideView`) renders the icon at 16/32/64/128/512pt in light + dark + tinted side-by-side.

The renderer's `drawInkForm(in:theme:)` is the programmatic mirror of `Resources/AppIcon.svg`. Keep them synchronised.

**Force-unwrap audit:** zero `try!` and zero force-unwraps remain in shipping code (`Tests/` excepted). The single legitimate fatal-stop case (`StorageService` container init failure — DB unavailable) uses `preconditionFailure` with an explicit message rather than `try!`. `init?(coder:)` overrides for programmatic UIView subclasses return `nil` (paired with `@available(*, unavailable)`) instead of `fatalError()`.

**App Store metadata files** — `Resources/`:
- `Info.plist` — privacy usage descriptions (mic, speech, photos, camera), `UIDeviceFamily=[2]` (iPad-only), `CFBundleURLTypes` with scheme `ink`.
- `PrivacyInfo.xcprivacy` — declares no tracking, no data collection, plus required-reason API declarations for `UserDefaults` (CA92.1) and `FileTimestamp` (C617.1).
- `Ink.entitlements` — iCloud Drive (`CloudDocuments`) for container `iCloud.com.ink.app`, App Group `group.com.ink.app`.
- `InkWidget/InkWidget.entitlements` — App Group only.

**Required Xcode IDE setup** (these can't be created from Swift files):
1. Add a Widget Extension target named `InkWidget` and add the four `InkWidget/*.swift` files to it.
2. Add `WidgetDataWriter.swift` (specifically the `NotebookSummary` struct) to both targets via Target Membership.
3. Enable "App Groups" capability on both targets and check `group.com.ink.app`.
4. Enable "iCloud" → "iCloud Documents" on the main target with container `iCloud.com.ink.app`.
5. Run an asset-generation pass to populate `Assets.xcassets/AppIcon.appiconset` from `InkIconRenderer.assetSizes` (a small one-shot CLI script can call `renderer.render(...)` and write each PNG).

**Performance** — unverified by Instruments in this codebase pass. Profiling targets stated in the spec:
- Library scrolling 60 fps with 50 notebooks: thumbnails are loaded as `Data` from the SwiftData record, no on-the-fly file I/O — already meets the bar at typical sizes. If this regresses with > 200 notebooks: add a `NSCache<NSUUID, UIImage>` 50-image cap.
- Editor frame budget: PKCanvasView is preserved across page swaps (see Stage 4 docs), autosave + thumbnail are off the main actor, transcription + export are actors.
- Memory: NSCache for decoded images is in `PageThumbnailCache`. AVAudioPlayer is released by `AudioPlayerController` on `onDisappear`.
- Run Instruments on-device before App Store submission and add real numbers to this section.

## Stage completion state

| Stage | Status | Description |
|---|---|---|
| 1 | ✅ | Project structure, design system, all tokens, primitive components, StyleGuideView |
| 2 | ✅ | SwiftData models, StorageService, CloudSyncManager, unit tests |
| 3 | ✅ | Library: NavigationSplitView, subject sidebar, notebook grid, search, new notebook sheet |
| 4 | ✅ | Editor: PKCanvasView, page templates, tool palette, colour picker, autosave, page strip, minimap |
| 5 | ✅ | Text blocks: TextKit 2, rich text toolbar, markdown shortcuts, resize handles, link popover |
| 6 | ✅ | Images & media: four insertion sources, ImageProcessingService, transform handles, inline crop |
| 7 | ✅ | Audio: recording, on-device transcription, waveform, pins overlay, player popover |
| 8 | ✅ | PDF export: ExportService, options sheet, progress/success/error, sharing, recent exports |
| 9 | ✅ | Settings: theme cards, pencil, new pages, audio locale picker, iCloud, storage, about |
| 10 | ✅ | Polish: haptics, a11y, keyboard shortcuts, Spotlight, widgets, app icon, App Store prep |

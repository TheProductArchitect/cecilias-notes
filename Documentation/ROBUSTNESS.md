# Cecilia's Notes — Robustness & Threading Map

Last updated: 2026-07-09. Documents how major processes run, which thread owns them, known race/ANR/crash risks, and what was hardened in the robustness pass.

---

## Threading model (summary)

| Layer | Actor / thread | Rule |
|-------|----------------|------|
| SwiftUI views & `@Published` | `@MainActor` | Never mutate from UIKit/PencilKit delegates synchronously — defer with `Task { @MainActor in … }` |
| `StorageService` / SwiftData `mainContext` | `@MainActor` | All fetches and `context.save()` on main; heavy decode/export off-main |
| `StrokeCache` | `@MainActor` | Write-through on stroke edits; PKDrawing decode in `Task.detached` |
| `MainThreadWatchdog` | Background queue | Records hangs synchronously via `SessionHealth` (UserDefaults + latch, no `main.async`) |
| MCP `.inkbook` export | `Task.detached` — build AND write on a background `ModelContext` | Pass notebook IDs across the boundary, never model objects |
| Vision / OCR / shape detect | `Task.detached` | Results applied on main only |
| UI tests (`-uiTesting`) | Main | Wipes store; CloudKit disabled in container |

---

## Process map

### 1. Cold launch

```
UIApplicationDelegate.didFinishLaunching
  → LaunchRecovery snapshot (app.shutdown.clean)
  → ModelContainer.truncateWALIfPresent [userInitiated queue, sync wait — always, any WAL size]
  → SessionHealth.consumeHadHangOnPriorSession()
  → ModelContainer.ceciliasNotesContainer() [WAL truncate again if delegate skipped — no-op when clean]
  → StorageService.init [@MainActor]
       → purgeDuplicateRows() [tombstone-aware, sync]
       → reconcileSoftDeleteFlags()  [deferred Task — not on launch critical path]
  → SwiftUI RootView → LibraryView.onAppear
       → drainPendingNotebookDeepLink() [launch resume missed by onChange]
       → runOneTimePageCountBackfillIfNeeded()
       → scheduleExportAll()  [entire build+write on a background ModelContext]
       → SearchIndexService.loadAsync()
```

**ANR risks:** Large notebook host rebuild; overlay `@ObservedObject viewModel` fan-out (Text/Sticky/Shape still full VM).

### 2. Editor open

```
Library tap → EditorViewModel.init
  → fetchPages + dedupe
  → StrokeCache.prewarmNotebook [detached decode, main insert]
ContinuousCanvasView.makeUIView
  → rebuildPageHosts [all page UIKit hosts + PageOverlaysContainer]
  → mountActivePageCanvasFirst [one PKCanvasView]
  → next runloop: updateCanvasMembership [remaining warm band]
mountCanvas
  → cache hit: sync assign drawing
  → cache miss: empty drawing + detached PKDrawing decode
       → generation guard + skip if isDirty before apply
```

**Mitigations applied:** Active-page-first canvas mount; async stroke decode with generation/isDirty guard; cached overlay fetches (Audio/Image/PDF/Highlight).

### 3. Drawing & autosave

```
PKCanvasViewDelegate.canvasViewDrawingDidChange
  → hosts[i].isDirty = true
  → debounced 1.2s Task → savePage → updatePageStrokes → context.save
  → StrokeCache write-through
```

**Stroke save ownership:** `EditorViewModel.performSave` / vm-level `flushPendingSaveSync` stroke path removed — only per-host debounce + `canvasFlushAllHandler` flush dirty pages.

**Race risks:** Single `viewModel.canvasView` pointer vs multi-page canvases — undo may target wrong page if user scrolls mid-stroke. **Open issue R2:** per-page canvas map.

**Shape recognition:** Pins `(canvas, pageId)` at stroke end; atomic undo grouping; `savePage` + cache write-through on apply; pill undo uses pinned `pageId` + `canvasForPageHandler`.

### 4. Lasso / stroke rewrite

```
Lasso commit → LassoGroupOps → SwiftData + StrokeCache
  → Notification.strokeContentRewritten
  → cancel pending host saves → reloadCanvases [authoritative cache apply]
```

### 5. Background / terminate

```
UIApplication.didEnterBackgroundNotification → EditorViewModel.handleAppBackground
  → flushPendingSaveSync → canvasFlushAllHandler → flushAllDirty
applicationDidEnterBackground
  → shutdown clean ONLY if !SessionHealth.hadHangThisSession
  → scheduleExportAll()
applicationWillTerminate
  → same hang guard for shutdown flag
  → scheduleExportAll() + RecordingSession.stop
```

**ANR recovery:** `ceciliasnotes.session.hadMainThreadHang` persisted from watchdog queue (not `main.async`) + dirty shutdown → library home, no auto-resume.

### 6. Foreground CloudKit / remote change

```
NSPersistentStoreRemoteChange → scheduleDuplicateSweep (2s debounce)
  → purgeDuplicateRows [tombstone wins over fresher shadow]
  → reconcileSoftDeleteFlags
```

**Churn risk:** REVERTED logs mean something un-deletes rows after reconcile — tombstone-aware dedupe + `deletedAt` belt on `fetchAllNotebooks` reduce resurrection; root reverter still TBD.

---

## Severity matrix (open items)

| ID | Issue | Severity | Status |
|----|-------|----------|--------|
| R1 | WAL checkpoint blocking mainContext on relaunch | ANR | **Fixed** — always truncate pre-open on userInitiated queue (delegate + container) |
| R2 | Single `canvasView` for multi-page editor | Race | **Mitigated** — per-page canvas in overlay inputs; active-page-only `canvasView` binding; batched canvas mount on scroll-rest |
| R3 | Full `viewModel` on Text/Sticky/Shape overlays | ANR | **Mitigated** — `EditorPageOverlayInputs` + `Equatable`; thin `let viewModel` for mutations |
| R4 | Sync `savePage` on canvas unmount | ANR | **Mitigated** — StrokeCache write-through + batched deferred SwiftData flush |
| R5 | Soft-delete REVERTED churn | Data + ANR | **Mitigated** — tombstone dedupe + deletedAt fetch belt |
| R6 | `pointHitsInteractiveElement` SwiftData fetch per tap | ANR micro | **Fixed** — per-page rect cache invalidated on element notifications |
| R7 | `@Published` from scroll delegate (some paths) | UI glitch | Partial |

### Fixed in robustness pass (2026-07-09)

| ID | Fix |
|----|-----|
| C1 | `SessionHealth` — `OSAllocatedUnfairLock` + synchronous UserDefaults from watchdog queue |
| C2 | `mountCanvas` — decode generation + `isDirty` guard; cancel decode on unmount |
| C3 | Retired vm-level stroke save; `handleAppBackground` → `flushPendingSaveSync` |
| C6 | `LibraryView.drainPendingNotebookDeepLink` on appear; launch resume gated on `resume.enabled` |
| C7 | Tombstone-aware `purgeDuplicates`; `fetchAllNotebooks` requires `deletedAt == nil` |
| C8 | Audio finger yield under drawing tools (`pointHitsAudioElement`) |
| — | Shape undo grouping + `PendingShapeReplacement.pageId` |
| — | Import `resetPages` deletes `PageElement` rows |
| — | Lasso `reloadCanvases` authoritative (no `isDirty` skip) |
| — | V5/V6 wipe uses correct `-wal` / `-shm` path suffix |
| — | Search index `refreshAll()` after `loadAsync()` on library mount |
| — | Per-page overlay canvas via `canvasForPageHandler`; Text/Sticky/Shape equatable inputs |
| — | Unmount saves batched via StrokeCache + deferred `savePage` |
| — | Interactive element hit-test rect cache per page |
| — | Launch WAL always truncated before container open (large sidecars no longer deferred) |
| — | Overlay hosts unmount off-band; tighter overlay warm band (0.25× viewport); `currentPageIndex` deferred until scroll-rest |
| — | Page hosts mount in batches of 3; canvas mounts deferred mid-scroll |
| — | Unmount stroke snapshots at capture time (fixes phantom undo on remount) |

---

## Removed test / diagnostic infrastructure

| Removed | Reason |
|---------|--------|
| `HostingHierarchyDiagnostics.swift` | Concluded investigation; swizzle overhead |
| `TouchPathLogger.swift` + attach sites | Touch-path probe no longer needed |
| `FourFingerTapDetector` in `RootView` | Dead code (empty handler) |
| Verbose `dlog` clusters | `[GestureAudit]`, `[StickyGesture]`, `[ImageGesture]`, `[AudioPlay]`, `[Pencil-diag]`, `[StateMachine-diag]`, `[BrandIcon][diag]`, `[RecordingMirror]` |

**Kept:** `dlog()` infra (DEBUG-only), `-uiTesting` / `resetForUITesting`, `MainThreadWatchdog`, `SessionHealth`, Mac DEBUG settings tab, `DebugLog.swift`.

---

## Tool-by-tool expectations

| Tool | Main-thread work | Failure mode | Guard |
|------|------------------|--------------|-------|
| Pen / pencil | PencilKit ink | ANR if overlays invalidate whole tree | Cached overlays; audio ticks isolated |
| Eraser | PK erase | — | Shape recognition skipped |
| Lasso | Selection + stroke rewrite | Stale canvas if reload races | Authoritative reload; cache write-through |
| Shape tool | SwiftUI drag → PageElement | — | Separate from stroke shape recognition |
| Shape recognition | 600ms timer + Vision | Phantom undo if cache stale | Cache + savePage on apply; undo grouping |
| Text / sticky | UITextView layout | TextKit compat warnings | — |
| Audio | AVAudioSession + 10Hz UI | Session conflicts; play blocked under pen | Finger yield on audio rects even in drawing mode |
| Highlighter | PDF text detect + element create | Undo grouping | `EditorViewModel+Highlighter` |
| Sync / export | SwiftData + JSON | Launch hitch | `scheduleExportAll` |

---

## Verification checklist

- [ ] Cold launch after force-quit during editor → library home, no auto-resume
- [ ] Open 3+ page notebook → first page interactive before siblings mount
- [ ] Draw + shape recognition → no phantom revert on scroll
- [ ] Background after normal session → clean shutdown, resume works
- [ ] Background after ANR → dirty shutdown, no resume
- [ ] Audio play button works while pen tool selected
- [ ] Lasso move → canvas matches model without next-stroke clobber
- [ ] UI tests still pass with `-uiTesting`

# Production Readiness — Final Pre-Submission Audit

Snapshot of `iphone-support` branch state at the App Store submission
cut. What's signed off, what still needs human attention, and what's
known-and-accepted.

---

## Update — 2026-07-03 (stability + interaction-correctness pass)

State after the July hardening sessions on `main`. Everything below
is code-verified AND simulator-verified unless marked otherwise.

### Tests
- **Unit: 122 pass, 1 pre-existing fail** (`ShapeDetectionTests.
  test_recogniseRectangle` — Vision returns nil on the iOS 26.4
  simulator runtime; untouched code, tracked below).
- **UI: 10/10 pass** on iPad Pro 13" (M5), iOS 26.4 — new end-to-end
  suites for dictation, undo/redo, and lasso (select/delete/undo/redo
  across strokes, text, shapes; move/resize/rotate with undo).

### Fixed since the original audit
- **Dictation freeze**: WAL checkpoint at launch + page append at
  notebook end; end-to-end test guards the responsiveness budget.
- **Undo/redo overhaul**: per-page undo scoping (was one window-wide
  stack interleaving all pages, with dead entries after canvas
  recycling); redo-stack registration fixed (mirror actions were
  landing on the undo stack); every element kind now registers undo
  for create, delete (lasso + direct), and move/resize/rotate
  (lasso chrome + per-element handles).
- **Lasso correctness**: highlights selectable (were never hit-
  testable), stroke edits reload the live canvas (moves/deletes were
  invisible and self-reverting), tap-clear race fixed (delete badge
  and cursor-tap select both raced the global deselect gesture),
  rotate recomputes the selection bounds (chrome no longer detaches).
- **Recording data-loss paths**: adoptAudio failure surfaces an error
  instead of silently discarding; `applicationWillTerminate` stops an
  active recording; dirty-launch streak no longer contaminated by UI
  test runs; deliberate local-only mode no longer shows the iCloud
  failure banner.
- **MCP import ordering**: imports serialized FIFO (out-of-order
  clobber race). MCP contract now documented in `MCP_SPEC.md`
  (source of truth going forward).

### Update — 2026-07-03 (evening: feedback round + latent-bug sweep)
- **On-device dictation freeze fully resolved** (user-verified on
  hardware): every Core Audio IPC call (tap install/remove, engine
  prepare/start/stop/pause, session deactivate) now runs off the
  main thread in LectureRecorder.
- **Shape picker tap race** fixed (tool switch deferred past popover
  dismissal); **freeform lasso** now draws a convex-hull outline
  hugging the selected content; **page centering** no longer leans
  left (palette-strip reservation is now proportional); **quiz
  builder** greys out sources below a 200-char context threshold
  and reads legacy TextBlock text (all MCP/AI-imported notebooks).
- **Latent bug found by new tests**: `TextBlock.isDeleted` writes
  are silently dropped at runtime (name collision with
  NSManagedObject's built-in `isDeleted`) — the flag always reads
  false. Every soft-delete read path (render overlay, search, page
  duplication, quiz collector) now checks `deletedAt == nil`, which
  round-trips reliably. Audit note: `Notebook.isDeleted` /
  `Page.isDeleted` predicates are query-level and their delete
  flows work in-app, but the same collision class deserves a look
  if soft-delete anomalies ever surface there.
- Tests now: **130 unit pass / 1 pre-existing fail**; lasso,
  undo/redo, and dictation UI suites pass.

### New known items (non-blocking, tracked)
- `test_recogniseRectangle` regressed with the Xcode/iOS 26.4 runtime
  update (was documented as "unimplemented"; circle + squiggle pass).
- Finger shape-drag also scrolls the canvas (Pencil path is fixed;
  finger-only users see displaced shapes). Real-device Pencil users
  unaffected.
- Highlighter tool's stroke-swap undo is one-shot (undo works, redo
  of that specific action doesn't re-apply).
- MCP/AI-written text is legacy `TextBlock` — renders and exports
  correctly but not lasso-selectable until the V6 text migration.
- New-notebook flow opens the customise sheet with title editing
  active and lands in cursor mode — two taps of friction before
  writing; product decision pending.

---

## ✅ Code state

### Builds
- **Release build clean** — zero compiler warnings (one ignorable
  `AppIntents metadata extraction skipped` from the toolchain which is
  unrelated to the app).
- **Debug build clean.**
- Both build on iPhone + iPad simulators.

### Tests
- **114 unit tests passing.**
- 1 known pre-existing failure: `ShapeDetectionTests.test_recogniseRectangle()`.
  The stroke recogniser today identifies lines and circles only;
  rectangle detection is unimplemented territory. Users now have the
  shapes tool as the primary path for shape primitives, so this is
  documentation-worthy but not blocking.

### Logging
- All `print(...)` routed through `dlog(...)` (`Core/Utilities/DebugLog.swift`).
- `dlog` is a no-op in Release — argument evaluation + the `Swift.print`
  call are both elided by the optimiser. App Store users see zero
  `[Tag] …` lines in the system log.
- DEBUG diagnostic surfaces (`[QuizGen]`, `[PDFExtract]`,
  `[ImageGesture]`, `[BrandIcon]`, etc.) are useful for next-time
  triage and absent from production builds.

### Crash + input hardening
- `NSKeyedUnarchiver` calls use `requiringSecureCoding: true`.
- `EditorViewModel.currentPage` clamps a stale `currentPageIndex`
  instead of an out-of-bounds subscript.
- `PageStripView` scroll-to guarded against negative index.
- `PDFPagePickerSheet` jump field unconditionally resigns the
  keyboard and shows an inline error for out-of-range input.
- CustomisePanel + PDFPagePickerSheet `onDisappear { resignFirstResponder }`
  closes the `_UIRemoteKeyboardPlaceholderView` constraint crash window.
- Apple Intelligence prompt corpus truncated to 9.5k chars + question
  count clamped to ≤20 so the 4096-token context window can't be
  exceeded again.

### Dead code removed
- `OnDeviceQuizGenerator.swift` (1,000-line retired quiz tier).
- `PDFReferenceImporter.importAllPagesIntoNewNotebook(from:)` (no
  callers — replaced by `importPagesFromLibrary` + `importPages`).
- `GeneratedQuestion` struct preserved in its own file as the value
  type the AI + MCP generators hand back to the persistence layer.

### iPad behaviour
- Every iphone-support change gated on
  `DeviceCapabilities.isPhoneIdiom`; the iPad code paths resolve
  byte-equivalent to pre-branch main. Unit suite verifies the gate
  decoupling didn't regress storage or naming.

### iPhone behaviour
- Compact masthead, sidebar drawer, single-column editor.
- Pencil scroll in cursor mode.
- Pencil-only shape draw when a Pencil is detected.
- Shapes selectable / movable / resizable via cursor + tap +
  lasso chrome handover.
- Cross-page image drag handoff via canvas-coordinator notification.

---

## 🟡 Verified in code, NEEDS real-hardware test

These compile and pass unit tests but the simulator can't fully
exercise them. Mark a TestFlight pass against each before App Store.

| Path                                                | Why simulator can't cover it                                |
|-----------------------------------------------------|-------------------------------------------------------------|
| Apple Pencil double-tap / squeeze                   | Simulator emits no Pencil-Pro telemetry                     |
| PencilKit drawing pressure / tilt                   | Real Pencil hardware only                                   |
| Audio recording + transcription                     | Mic + SFSpeechRecognizer offline behaviour                  |
| CloudKit cross-device sync                          | Two real signed-in devices required                         |
| Apple Intelligence quiz generation                  | iOS 26 device + A17 Pro / M-series + AI enabled in Settings |
| Share-extension PDF intake from Files / Mail        | Cross-process inbox handoff                                 |
| Pixel-eraser tip width                              | Bitmap eraser visual quality                                |
| Image cross-page drag (continuous scroll across pages) | Real touch + scroll inertia                              |

---

## 🟠 Open items before App Store

### Privacy + entitlements (CAN'T verify from code)
- [ ] `PrivacyInfo.xcprivacy` declares the required-reason APIs
      (UserDefaults, file timestamps, CloudKit).
- [ ] No `NSUserTrackingUsageDescription` key (app doesn't track).
- [ ] iCloud entitlement for `iCloud.app.ceciliasnotes` verified in
      App Store Connect.

### App Store metadata
- [ ] Description, keywords, subtitle, "what's new" copy uploaded.
      First-cut copy at `Documentation/APP_STORE_COPY.md`.
- [ ] Screenshots produced from real devices (iPad Pro 13", iPhone
      17 Pro Max minimum). I cannot generate these; checklist in
      the copy doc.
- [ ] App icon (1024 + bundled sizes) already complete in
      `Assets.xcassets/AppIcon.appiconset`.
- [ ] Support URL, marketing URL, privacy policy URL.
- [ ] Age rating: **4+** (no age-restricted content).

### Accessibility audit (NOT verified)
- [ ] VoiceOver pass on library / editor / settings.
- [ ] Dynamic Type — typography uses `.system(size:)` fixed sizes;
      they will not respond to user font size. Decision needed
      before submission: ship as-is (editorial design intent) or
      fold in Dynamic Type for readability-critical surfaces.
- [ ] Reduce Motion — most spring animations honour
      `@Environment(\.accessibilityReduceMotion)`; spot-check the
      editor.

### Performance on real hardware
- [ ] 1000-notebook library smoke (verified synthetic; not on
      real iPad).
- [ ] Pencil-stroke latency target 60 fps on iPad Pro.
- [ ] Cold-launch time after the editor-mount eager warm-band pass.

### Documented inherited limitations
- **Stroke recognition** identifies lines + circles only. Triangle /
  rectangle land in the user-facing shapes tool instead.
- **Quiz generation** capped at 20 questions per quiz (Apple
  Intelligence context window). Users generate a second quiz from
  the same source if they need more.
- **PDF source budget** ~9.5k chars per generation pass (Apple
  Intelligence context window). Chunked generation against larger
  sources is a follow-up.
- **CloudKit local-cache permission errors** (`Cocoa 257`) need an
  app uninstall/reinstall to clear; not fixable from code.
- **Diarisation** (speaker identification in transcripts) is not
  available — no free on-device iOS solution today. Apple
  Intelligence handles heading detection in the transcript itself
  via `IntelligenceService.structureTranscript(_:)`.

---

## Test runbook

### Local

```
xcodebuild test \
  -project CeciliasNotes.xcodeproj \
  -scheme CeciliasNotes \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' \
  -only-testing CeciliasNotesTests
```

Expected: **114 pass, 1 pre-existing fail** (rectangle stroke recognition).

### Release build

```
xcodebuild build \
  -project CeciliasNotes.xcodeproj \
  -scheme CeciliasNotes \
  -configuration Release \
  -destination 'generic/platform=iOS'
```

Expected: **BUILD SUCCEEDED**, zero warnings (other than the
toolchain-side `AppIntents metadata extraction skipped` note which
applies to every project without an AppIntents.framework dependency).

---

## Sign-off

**Code state:** ready for TestFlight upload + App Review submission.
**Hardware testing:** required before promoting to App Store.
**Open metadata / privacy / a11y items:** addressable in
1–3 days of focused human work; none block submission *per se*
but most are required by App Review (privacy policy URL,
screenshots).

If a TestFlight pass on iPad + iPhone is clean, the next step is:

1. Archive (Product → Archive in Xcode).
2. Validate in Organizer.
3. Upload to App Store Connect.
4. Fill in metadata using the doc at
   `Documentation/APP_STORE_COPY.md`.
5. Submit for review.

---

## Update — 2026-07-06 (Mac companion production pass)

### Mac target
- **Icons** — `CeciliasNotesMac/Resources/Assets.xcassets/AppIcon.appiconset` (all macOS sizes from iPad 1024 master)
- **Build** — Debug + Release green; `CURRENT_PROJECT_VERSION = 2` matches iOS
- **Editor parity** — rotate/crop/OCR, PDF page import, find-replace, element keyboard nav
- **Export** — share sheet via `NSSharingServicePicker`
- **Copy** — `Documentation/APP_STORE_COPY.md` includes Mac subtitle + description

### Mac App Store Connect (human)
1. Upload Mac build from same Xcode archive (Universal Purchase)
2. Add macOS screenshots (1280×800 or 1440×900 recommended)
3. Confirm Mac category: Productivity
4. Privacy nutrition labels match iOS (no data collection)
5. Smoke test: iCloud sync, Multipeer with iPad, PDF import, export share

---

## Update — 2026-07-10 (crash + ANR hardening rounds)

State after the July 8–10 sessions. Everything code-verified;
both targets build and the full unit suite is green after each
round (commits `c424991` → `e3f6384`).

### Crashes (App Store review + device reports)
- **Voice-note / dictation SIGTRAP (review, 2.1(1))** — audio tap
  closures were MainActor-isolated under `@preconcurrency` and ran
  on AVFAudio's queue. Fixed (`d360d2b`); Speech callbacks hardened
  with explicit `@Sendable`.
- **Color-picker eyedropper SIGABRT (review, 2.1(1)+2.1(3))** —
  picker hosted inside the tool-palette popover died mid-eyedropper.
  Now a UIKit formSheet from the top-most VC (`c424991`).
- **Post-dictation window** — summary-prepend geometry clamped;
  duplicate-purge now nudges overlays to re-fetch so deleted
  SwiftData instances are never re-rendered (`aebc7ff`).
- Reviewer's exact voice-note steps reproduced green in
  `VoiceNoteFlowUITests` on the iPad (M5) iOS 26.4 simulator.

### ANRs
- Keystroke persist debounced + archive off-main; dictation saves
  throttled to 1/s; `.inkbook` mirror builds on a background
  `ModelContext`; hygiene sweeps fetch only mismatched rows
  (`3f2ccb6`).
- Stroke blob fetch AND decode off-main at canvas mount; stroke
  encode off-main for draw-debounce/unmount saves; dictation
  UITextView relayout coalesced to 4/s (`e3f6384`).
- **Phantom undo** — iPadOS three-finger swipe fired PencilKit's
  stroke undo during multi-finger scrolls; canvases now opt out
  via `editingInteractionConfiguration = .none` (`e3f6384`).
- **Draw-time freeze with a stale paired peer** — notebook-changed
  hints ran `MCSession.send(.reliable)` on the main thread on every
  debounced stroke save; a peer that left the LAN leaves a zombie
  DTLS link ("No route to host") that blocks each send for seconds
  while still listed as connected. All multipeer sends now egress
  on `MultipeerSendQueue`; hints coalesced to 1 per 3 s per notebook.
- **Draw-time freeze #2 (device-log confirmed, 2026-07-10)** — the
  page-strip thumbnail key fingerprinted the stroke BYTES, so every
  save tick and every strip-row body eval pulled the full multi-MB
  stroke blob out of SQLite on the main actor (twice on a miss), and
  `StrokeCache` prewarm read the first N page blobs on main at editor
  open. The console capture showed continuous main-thread
  `sqlite3_step` faults while drawing. Keys are now
  `(pageId, page.updatedAt, pdfFingerprint)`; renders resolve strokes
  from `StrokeCache` or a background `ModelContext`; the rasteriser
  is explicitly `nonisolated`; prewarm fetches+decodes off main.

### Submission status
- **3.0 (3) predates all of the above** — archive a fresh build
  from `main` before the next review round (OPEN_ISSUES §4).

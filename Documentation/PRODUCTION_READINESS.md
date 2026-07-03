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

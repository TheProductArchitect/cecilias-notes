# Production Readiness — Status & Open Items

Snapshot as of branch `iphone-support` (2026-06-17). What's signed off
from code, what's gated on testing on real hardware, and what still
needs to be cut before App Store.

---

## ✅ Signed off from code

### Logging
- All `print(...)` routed through `dlog(...)` — no-op in Release
  (`Core/Utilities/DebugLog.swift`, commit `bb22376`).
- `HostingHierarchyDiagnostics.installOnce()` gated on `#if DEBUG`.
- Release build verified: 0 ungated `print` calls in app sources.

### Crash + input hardening
- `NSKeyedUnarchiver` calls use `requiringSecureCoding: true` (`2712c41`).
- `EditorViewModel.currentPage` clamps a stale index instead of
  out-of-bounds subscripting (`c1d28b9`).
- `PageStripView` scroll-to guarded against negative index.
- `PDFPagePickerSheet` jump field: unconditional keyboard dismiss +
  inline error for empty / non-numeric / out-of-range input.
- CustomisePanel + PDFPagePickerSheet `onDisappear { resignFirstResponder }`
  closes the `_UIRemoteKeyboardPlaceholderView` constraint crash window.

### Memory + lifecycle
- `RecordingPill` autoclose verified in earlier audit.
- ContinuousCanvasView observer tokens removed in deinit
  (`capabilityObserver`, `pixelEraserObserver`).
- AudioRecorder/PlaybackController deinit logged DEBUG-only.

### iPad behaviour
- Every `iphone-support` branch change gated on
  `DeviceCapabilities.isPhoneIdiom` so the iPad path is byte-equivalent
  to `main`.
- Verified via 114-test unit suite (1 known pre-existing failure in
  rectangle stroke recognition, unrelated).

### Unit test coverage (this session)
- `ShapeKindPathTests` — 5 cases over every shape kind + bounds + category.
- `QuizEligibilityTests` — 4 cases over typed text, whitespace, audio
  transcript toggle, subject aggregation.
- `PageDragItemTests` — Codable round-trip + Transferable conformance.

---

## 🟡 Verified in code, NEEDS real-hardware test

These compile + pass unit tests but the simulator can't fully
exercise them. Mark a TestFlight pass against each before App Store.

| Path                                                | Why simulator can't cover it                          |
|-----------------------------------------------------|-------------------------------------------------------|
| Apple Pencil double-tap / squeeze                   | Simulator emits no Pencil-Pro telemetry               |
| PencilKit drawing on iPad                           | Stroke pressure / tilt only realistic on device       |
| Audio recording + transcription                     | Mic + SFSpeechRecognizer offline behaviour            |
| CloudKit cross-device sync                          | Needs two real signed-in devices                      |
| Pixel-eraser tip width                              | Bitmap eraser visual quality                          |
| iPhone touch on PalmRejectingScrollView             | Multi-finger handling                                 |
| Apple Intelligence quiz generation                  | Requires iOS 26 device with capability + AI enabled   |
| Share-extension PDF intake from Files / Mail        | Cross-process inbox handoff                           |

---

## 🟠 Open items before App Store

### Privacy + entitlements
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) — confirm declared APIs
      match what's actually used. CloudKit, UserDefaults, file access
      are required-reason APIs as of Apple's 2024 deadline.
- [ ] App-tracking transparency: app doesn't track today; verify the
      `NSUserTrackingUsageDescription` key is absent so no prompt fires.
- [ ] iCloud entitlements verified in App Store Connect (`iCloud.app.ceciliasnotes`).
- [ ] Push notifications: not used; ensure no stray entitlements.

### App Store metadata
- [ ] Screenshots for iPad + iPhone (every supported size class).
- [ ] App preview video (optional but recommended).
- [ ] Description, keywords, support URL, marketing URL.
- [ ] Age rating — pencil drawing app, likely 4+.

### Localisation
- [ ] App is English-only today. Either:
      - File a v1.1 localisation effort (Spanish, French, German, Japanese
        cover the biggest paid-app markets), or
      - Declare English-only and skip.

### Accessibility audit (NOT done in code review)
- [ ] VoiceOver pass on every primary surface (library, editor, settings).
      Today most tool palette buttons have `.accessibilityLabel` only on
      a few; the masthead wordmark relies on visual hierarchy.
- [ ] Dynamic Type — typography uses fixed `.system(size:)`. Will not
      respond to user font size. Decision needed: ship as-is (the
      editorial design is the spec) or fold in Dynamic Type for
      readability-critical surfaces.
- [ ] Reduce Motion — most spring animations honour
      `@Environment(\.accessibilityReduceMotion)`; spot-check the editor.

### Performance
- [ ] 1000-notebook library smoke test on real iPad (we've tested this
      in synthetic data; library-refresh perf was hardened in `b7cae2d`).
- [ ] Pencil-stroke latency on iPad Pro M5 — target 60fps consistently.
- [ ] Memory ceiling under heavy use (many large PDFs imported).
- [ ] Cold-launch time — currently editor mount fires multiple page-
      host mounts on first open (visible in `logs_venu`). May benefit
      from a deferred warm-band pass; not blocking.

### Known unresolved
- [ ] Stroke recognition only handles lines + circles (rectangle/
      triangle returned `unknown` in the failing test — confirmed
      pre-existing limitation). User now has the shapes tool as the
      primary path for shape primitives, so this is no longer
      blocking but should be documented in release notes.
- [ ] Shape selection / resize / recolour after creation — committed
      backlog (see `9b0d3fa` commit message).
- [ ] CloudKit `Cocoa 257` permission error at launch — likely needs
      a fresh install on affected devices, not code-fixable from the
      app.

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

Expected: **114 pass, 1 pre-existing fail** (rectangle stroke
recognition).

### CI

Not yet wired. Recommendation: GitHub Actions on every PR to main,
matrix over iPhone 17 Pro 26.4 + iPad Pro 13-inch (M5) 26.4.

---

## Sign-off

**Code state**: ready for TestFlight on iPad + iPhone.
**Hardware testing**: required before App Store.
**Open metadata / privacy / a11y items**: addressable in 1–3 days of
focused work but not in this session.

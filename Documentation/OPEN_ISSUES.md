# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-05-20 (branch `bug-fixes`). Resolved
items should be deleted from this file, not struck through — git
history is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact, not
the engineering effort.

---

## 1. Alternate app-icon swap fails on iOS 26 — MEDIUM

**Symptom.** `setAlternateIconName(_:)` fails when called near
onboarding completion — `NSPOSIXErrorDomain` 35 (EAGAIN), then
`NSCocoaErrorDomain` 3072 ("cancelled"). The home-screen icon
silently doesn't change to the user's initial.

**Cause (hypothesis, well-supported).** The onboarding name field's
keyboard is mid-dismiss when the call fires; the keyboard layer's
teardown blocks `LSIconAlertManager` from acquiring the presentation
token for the mandatory (un-suppressable) icon-change alert. Device
logs show `UIKeyboardImpl` snapshotting "not in visible window"
between retry attempts.

**Tried and failed.** (1) Moved the call onboarding → `LibraryView.onAppear`
(`a7b6140`). (2) EAGAIN-aware retry with backoff (`16aeb92`).
Neither helped — the keyboard is still mid-dismiss.

**Ruled out — do not retry.**
- *Plain retry loops.* Every retry hits the same EAGAIN → "cancelled"
  condition. Retrying without changing the scene/keyboard state
  changes nothing — this is exactly why the fix is a state *gate*,
  not more retries.
- *Relocating the call to another view's `onAppear`.* onboarding →
  `LibraryView.onAppear` didn't help; the keyboard is still
  tearing down wherever the call lands immediately after onboarding.
- *Removing `.environment(\.theme)` / `.preferredColorScheme` from
  the `WindowGroup`.* An A/B test suggested this lets the call land,
  but those modifiers are load-bearing for the whole theme system
  and cannot be removed. Not a usable fix.

**In place now.** `IconUpdateGate` (`33f3f42`) holds the swap until
the scene is foreground-active **and** the keyboard is fully
dismissed (`keyboardDidHide` with no later `keyboardDidShow`; 10s
safety timeout). Primed at app launch so its keyboard observers
exist before onboarding raises the keyboard. A 3× retry remains as
a defensive fallback. Diagnostic `[BrandIcon][diag]` logs at every
gate transition.

**Logging.** `[BrandIcon][diag]` (not `#if DEBUG`-gated — survives
in Release):
- gate lifecycle — `gate — keyboardDidShow/keyboardDidHide`,
  `gate — scene didActivate/willDeactivate`.
- gate decision — `gate ready immediately — firing`,
  `gate waiting — keyboardVisible=… sceneActive=…`,
  `gate now ready — firing pending completion`,
  `gate timeout (10s) — firing anyway`.
- the swap — `icon update pending for key=…`,
  `setAlternateIconName(<key>) — attempt (<n> left)`,
  `setAlternateIconName(<key>) SUCCESS` / `… FAILED: <error>`.
A clean run reads: pending → gate waiting → keyboardDidHide → gate
now ready → attempt → SUCCESS.

**Next step.** Device-confirm the gate lets the swap land
(`[BrandIcon][diag] gate now ready` → `setAlternateIconName(…)
SUCCESS`). If it still fails, the practical resolution is to move
the icon swap to an explicit Settings row (a fully-settled scene)
and file Apple Feedback — stop speculative iteration.

---

## 2. Swift 6 language mode not adopted — LOW

**State.** The project builds in Swift 5 language mode
(`SWIFT_VERSION = 5.0`). Building under `SWIFT_VERSION=6` succeeds
with **0 errors but 37 strict-concurrency warnings**.

**Why unresolved.** Several warning sites need real restructuring of
concurrency boundaries — `PDFDocument` Sendability, `AVAudioPCMBuffer`
capture in a `@Sendable` closure, captured-`var` races in the media
pickers — and touch product-sensitive audio/PDF paths. Bigger than a
focused commit.

**Diagnosis — error cascade fixed in commit `f69c6ac`.** The
`SWIFT_VERSION=6` build had regressed from "0 errors" to a hard
multi-file *failure* after the word-level-audio and free-axis-resize
commits introduced new concurrency-crossing code. `f69c6ac` ("Swift 6
actor isolation cleanup") walked it back to 0 errors. The failures
clustered into six mechanisms — recorded so the cascade isn't
re-triggered or chased down a dead end:

1. **SwiftData `@Model` infects plain-struct `Codable` conformances
   with `@MainActor`.** A `struct: Codable` in the same module as
   `@Model` types had its *synthesised* `Decodable`/`Encodable`
   conformance inferred `@MainActor`-isolated — `JSONDecoder().decode(
   T.self, …)` from a `nonisolated` context then failed to compile.
   Hit `TimingMap` and `NotebookPreferences`. Fixes: for `TimingMap`,
   split it into a SwiftData-free file **and** mark the consuming
   `AudioContent.timingMap` accessor `@MainActor` (the accessor —
   annotating the struct itself does nothing). For
   `NotebookPreferences`, dropped `Codable`/`Equatable` and moved the
   store to `JSONSerialization` (raw `[String:Bool]`) — no conformance
   witness, nothing to infer; on-disk JSON format unchanged.
2. **`@preconcurrency import` is the lever for non-Sendable Apple
   framework types** (`PDFDocument`, `CGPDFPage`, `AVAudioPCMBuffer`,
   `SFSpeechAudioBufferRecognitionRequest`) — not per-call
   annotations. It *downgrades* the Sendable violation from error to
   warning; it does not erase it (those sites are still among the 37).
3. **`nonisolated` cascades.** Marking one method `nonisolated`
   forces every callee and every stored constant it touches to be
   `nonisolated` too — fix the whole call chain in one pass, not
   site by site.
4. **`deinit` of a `@MainActor` class cannot touch non-Sendable
   stored properties.** NotificationCenter observer tokens →
   `nonisolated(unsafe)` (legitimate — `removeObserver` is documented
   thread-safe). `AVAudioEngine` is *not* documented thread-safe →
   did not annotate it; dropped the `deinit` reference instead.
5. **`PDFAnnotation` subclasses** — the inherited designated
   initialiser `init(bounds:forType:withProperties:)` is inferred
   `@MainActor` against the framework's `nonisolated` base; needs an
   explicit `nonisolated override`.
6. **`Task.detached` capturing `@Model` instances** fails the
   `sending` check — switch to `Task(priority:)`, which inherits the
   caller's isolation so the model never crosses a boundary.

**Ruled out — do not retry.**
- *Moving a struct to its own file to escape the `@MainActor`-
  inferred `Codable` conformance.* Tried for `NotebookPreferences` —
  relocation alone did **not** clear the inference; the conformance
  had to be removed (mechanism 1), not moved.
- *`@preconcurrency import PDFKit` to silence a `CGPDFPage` warning.*
  `CGPDFPage` is a CoreGraphics type, not PDFKit — `@preconcurrency`
  only works on the *defining* module's import.
- *`nonisolated(unsafe)` to quiet any `deinit` / closure-capture
  warning.* Valid only for Apple-*documented* thread-safe types
  (NSCache, NotificationCenter tokens); on `AVAudioEngine` and
  friends it trades a warning for a latent data race — not a fix.

Side effect to sweep later: `f69c6ac`'s mechanism-5 annotations
added 4 *new* warnings — `nonisolated(unsafe)` is now unnecessary on
`UIImage` constants in `ExportService` / `PDFDerivedExport`
(`UIImage` gained `Sendable` in the iOS 26 SDK). Harmless; the
keyword can simply be deleted.

**Logging.** None — these are build-time diagnostics, not runtime
logs. Surface them with
`xcodebuild build … SWIFT_VERSION=6 | grep ": warning:"`.

**Next step.** See `ARCHITECTURE.md` → "Swift 6 migration status"
for the full per-file warning inventory. Complete the cleanup and
flip `SWIFT_VERSION` to `6.0` as a dedicated commit.

---

## 3. "Publishing changes from within view updates" warnings — LOW

**Symptom.** ~12 SwiftUI "Publishing changes from within view
updates" warnings fire during dictation start.

**In place now.** The `navigateToPage` cluster in
`startDictationRecording` — `refreshPages()` + `currentPageIndex` +
`pendingScrollPageIndex` — was wrapped in `Task { @MainActor in }`
(`91b0617`), moving that publish cluster out of the view-update
pass. `RecordingSession.state` was deliberately **not** deferred —
the dictation state machine depends on it being set synchronously.

**Why still open.** That cluster is the clearest evidenced offender,
but it likely doesn't account for all 12 warnings. Pinning the rest
needs the device-captured call-stack sites.

**Logging.** No dedicated tag — the signal is SwiftUI's own runtime
console line, *"Publishing changes from within view updates is not
allowed; this will cause undefined behavior."* Correlate it with the
`[Dictation]` start sequence (`RecordingSession.startDictation
entered`, `navigateToPage — newPageId=…`, `startDictation completed`)
to see which mutations coincide. There is no call-stack tag yet —
adding `Thread.callStackSymbols` at suspected publish sites is part
of the next step.

**Next step.** Capture the remaining warning stacks on device, then
defer only the genuinely-safe publish sites (never `state`).

---

## 4. Magnetic page zoom — not built (deferred feature)

**State.** Requested as a feature: page always centred, zoom
anchored to page centre, magnetic edges at 100%. **Not implemented.**

**Why deferred.** The request's spec assumed a single centred page
in its own scroll view. The editor is actually a *continuous
vertical scroll of all pages stacked in one `UIScrollView`*. The
proposed mechanic — disable scrolling at `zoomScale ≤ 1.0` — would
disable scrolling *between pages* at normal zoom, a severe
regression. Page centring is already handled by the existing
`applyContentInset()` in `ContinuousCanvasView`.

**Next step.** If still wanted, write a spec against the
continuous-scroll model (e.g. magnetic *horizontal* centring only,
leaving vertical paging untouched) before any implementation.

---

## Pending device verification (fix shipped, not yet confirmed)

Not open bugs — fixes that have landed but await a device pass.
Move to "resolved" (delete) once confirmed, or back into the list
above if they fail.

- **Dictation transcript reset on pause** — `LectureRecorder`'s
  `rotateRecognitionTaskIfStillRecording` now promotes the in-flight
  `liveTranscript` to `committedTranscript` when a recognition
  session ends without a final result (`91b0617`). Verify: speak,
  pause 5s, speak again — both sentences should remain.
  Logging (`[Dictation]`, `#if DEBUG`): `partial result, len=<n>`
  (watch for the length *not* dropping back across a pause),
  `rotation without final result — promoted <n>-char liveTranscript
  to committed` (the new fix firing), `handleLiveTranscript routing
  <n> chars`, `updateText OK — <n> total chars`.

- **Element-tap gesture absorption** (was issue #1, HIGH) — taps on
  image / sticky-note / audio elements never reached their SwiftUI
  element views; the `[ImageGesture] / [StickyGesture] / [AudioPlay]
  1. tap received` logs never fired, images couldn't be selected,
  the audio play button didn't respond.

  **Root cause — confirmed by the `[Renderer-hit]` diagnostic
  (`673f3c9`).** The earlier "prime suspect" (the `PKCanvasView`,
  mounted in `contentView` above the renderer, consuming the touch)
  was *wrong*. The `[Renderer-hit]` log showed `PageRenderer.hitTest`
  returning `_UIHostingView<LassoOverlayView>` for every page tap:
  the `LassoOverlayView` hosting view sits at the top of every
  renderer's subview stack (`subview[9]`), is full-page
  (`frame=(0,0,794,1123)`), and had `isUserInteractionEnabled = true`
  at all times — including when the lasso tool was inactive. UIKit's
  back-to-front hit-test walk stopped at the lasso host, so no touch
  ever reached the image / sticky / audio overlays below it.
  `LassoOverlayView`'s SwiftUI `.allowsHitTesting(isLassoActive ||
  selectionForThisPage)` self-gate does **not** propagate to the
  `_UIHostingView`, so the gate had to be applied at the UIKit layer.
  `PKCanvasView` is not in the renderer's subview list at all — the
  bug was entirely inside `PageRenderer`'s overlay stack.

  **Fix.** `ContinuousCanvasView.applyOverlayHitTestingToAll` now
  sets `lassoHost.view.isUserInteractionEnabled = tool.isLassoMode`
  on every tool change, and the lasso host is mounted non-interactive
  unless the lasso tool is already active. Subview z-order is
  unchanged — the lasso host correctly stays on top so its chrome
  draws above the other overlays when the tool is active.

  **Behaviour note.** The UIKit gate is tool-only, intentionally
  stricter than `LassoOverlayView`'s `isLassoActive ||
  selectionForThisPage` SwiftUI predicate. A lasso *selection* that
  survives a tool switch (which it does — `selectTool` does not
  clear it) stays visible but its chrome is not hit-testable until
  the user switches back to the lasso tool. If that regresses real
  usage, widen the gate with a `LassoSelectionState.hasSelection`
  signal — but first confirm the host doesn't re-absorb page taps in
  the selection-active state.

  Verify: outside lasso mode, tap an image / sticky note / audio play
  button → the matching `[ImageGesture] / [StickyGesture] /
  [AudioPlay] 1. tap received` log fires, and `[Renderer-hit]` shows
  `super.hitTest=_UIHostingView<ImageElementsOverlayView>` (or the
  sticky / audio equivalent) instead of `LassoOverlayView`. Switch to
  the lasso tool → drag-select still works. Pencil inking still works
  in inking modes. The `[Renderer-hit]` diagnostic (`673f3c9`) stays
  in `PageRenderer` for this verification pass — remove it in a
  separate commit once confirmed.

  Ruled out — do not retry (disproven by `[TouchPath]` +
  `[Renderer-hit]`):
  - *Element-view modifier reordering* (`contentShape` / `gesture` /
    `position` order). 4+ attempts. The touch never reached the
    element view — nothing in its modifier chain could be the cause.
  - *`.position → .offset` on the element views* (`91b0617`,
    reverted `c46440a`). Wrong layer; also broke scrolling.
  - *Adding more SwiftUI gestures* (`simultaneousGesture`,
    `highPriorityGesture`) inside the element views — same
    wrong-layer trap.
  - *`PKCanvasView` sibling z-order* — the hypothesis that the
    canvas, mounted in `contentView` above the renderer, consumed
    the touch. Disproven: `PKCanvasView` is not in the renderer's
    subview list, and `[Renderer-hit]` shows the touch dies inside
    the renderer's own overlay stack.
  - *`PageRenderer` absorbing the hit itself* — disproven by
    `[Renderer-hit]`: `super.hitTest` resolves to a subview
    (`_UIHostingView<LassoOverlayView>`), not the renderer.

  Audit-doc drift: `MEDIA_SUBSYSTEM_AUDIT.md` §1 tabulates seven
  per-page overlays; the renderer's actual subview stack has ten —
  it omits `LassoOverlayView`, `StrokeElementsOverlayView`, and
  `TextElementsOverlayView`. Flagged for the next audit refresh; no
  action needed here.

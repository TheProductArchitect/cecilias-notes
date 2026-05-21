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

**Fixed — self-healing reconcile (`788e753`).** The deeper bug was
that the swap was *one-shot*: `applyPendingIconUpdateIfNeeded()`
removed its `pendingIconUpdateKey` flag **before** attempting the
swap, so a single EAGAIN failure stranded the icon permanently — no
retry path, no user-facing control to re-trigger it. Replaced with
`reconcileAppIcon()`: idempotent and self-healing. It derives the
desired icon from the stored user name and runs a gated swap
whenever the live `alternateIconName` doesn't match; nothing is
consumed, so a failed attempt is simply retried by the next
reconcile. It runs from `LibraryView.onAppear` (every launch + every
return to the library) and on theme apply, so a swap that loses the
iOS 26 race during onboarding churn lands automatically on a later,
settled pass — no user action. `IconUpdateGate` still holds each
attempt until the scene is foreground-active and the keyboard
dismissed; `iconReconcileInFlight` guards against overlapping
attempts / duplicate system alerts. The previously ungated
`ThemeManager.updateAppIcon()` second call site now routes through
the same reconcile.

**Logging.** `[BrandIcon][diag]` (survives in Release):
`reconcile — current=… desired=… — handing to gate`,
`gate — keyboardDidShow/keyboardDidHide`,
`gate — scene didActivate/willDeactivate`, `gate ready immediately`,
`gate waiting …`, `gate now ready …`, `gate timeout (10s) …`,
`setAlternateIconName(<key>) — attempt (<n> left)`, `… SUCCESS` /
`… FAILED: <error>`.

**Next step — device-verify on iOS 26.4.** The one-shot trap is
definitively fixed. What remains unverified is whether iOS 26.4 lets
a settled-context attempt land at all. Reconcile now retries on
every launch, so a normal launch straight into the library (no
onboarding churn) is the settled context that should succeed —
expect `[BrandIcon][diag] reconcile …` → `gate now ready` →
`setAlternateIconName(…) SUCCESS`. If logs still show only `FAILED`
across several launches, the root cause is a genuine iOS 26
`LSIconAlertManager` regression — file Apple Feedback; the
self-healing reconcile is the most that can be done app-side.

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

  **Fix 1 — lasso host (`a2813c3`).**
  `ContinuousCanvasView.applyOverlayHitTestingToAll` now
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

  **Fix 2 — overlay background catchers.** After Fix 1 the
  `[Renderer-hit]` log confirmed `LassoOverlayView` inert
  (`subview[9] userInteraction=false`) but the absorber had moved one
  layer down: `_UIHostingView<TextElementsOverlayView>` (`subview[8]`,
  frontmost in cursor mode) now won every page tap. Each per-page
  overlay — text / image / sticky / audio — mounts a full-page
  `Color.clear.contentShape(Rectangle())` background tap-catcher
  whenever its tool predicate is active; in cursor mode all four are
  active at once and the topmost absorbs every tap, including taps
  meant for an element in an overlay below it. Crucially the catcher
  is usually a *no-op* — in cursor mode with nothing selected it
  catches the tap and does nothing.
  The four overlays now gate the catcher behind a
  `showsBackgroundCatcher` predicate: mounted only when it has work —
  an active selection / edit to dismiss (all four) or the overlay's
  own create-mode (text / sticky). When idle, no catcher is mounted,
  the overlay's `_UIHostingView` returns nil for non-element points,
  and UIKit's native reverse-z hit-test routes the tap to whichever
  overlay owns the tapped element — no container shim required.

  **Fix 1 and Fix 2 did not work — decisive finding.** Device logs
  after Fix 2 still showed `TextElementsOverlayView` absorbing every
  tap. The `[Renderer-hit]` per-subview probe settled it: a
  `_UIHostingView` claims its **entire frame** for hit-testing
  whenever `isUserInteractionEnabled` is true — proven by an overlay
  with zero elements and no catcher (`[TextCatcher v3]
  showsBackgroundCatcher=false elementCount=0`) still returning
  *itself* from `hitTest`. Every `userInteraction=true` overlay host
  claimed every point; every `userInteraction=false` host passed
  through. Hit-testing correlated 100% with the flag and 0% with
  content. `_UIHostingView` is *greedy* — it does not honour SwiftUI
  hit-test transparency at the host boundary. So nothing done inside
  an overlay's SwiftUI body (Fix 2's catcher gating) and no per-host
  z-order tweak (Fix 1) could ever route a tap past the topmost
  greedy host. The earlier "prime suspect" lines were all wrong; the
  prompt author's original "greedy full-bounds hit-testing" call was
  right.

  **Fix 3 — single overlay host (the actual fix).** The nine
  interactive overlays (stroke seed, legacy text-block, image, PDF
  page, highlight, audio, sticky, V6 text element, lasso) are now
  children of one `PageOverlaysContainer` ZStack mounted in a single
  `UIHostingController`. One `_UIHostingView` ⇒ hit routing happens
  *inside* one SwiftUI tree, where SwiftUI correctly delivers each
  tap to the element (or background catcher) actually at the point.
  Cross-host absorption is now structurally impossible. The mount
  code in `ContinuousCanvasView` builds one host per page instead of
  nine; `promoteActiveOverlayToFront` is deleted (a fixed ZStack
  order replaces it); `applyOverlayHitTestingToAll`'s lasso gating is
  removed (`LassoOverlayView`'s own `.allowsHitTesting` is honoured
  now that it shares the tree). Fix 2's `showsBackgroundCatcher`
  gating stays and is now load-bearing — within one tree a gated-off
  catcher genuinely lets SwiftUI route around it. The template
  pattern stays a separate non-interactive host.

  Verify: tap an image / sticky note / audio play button → the
  matching `[ImageGesture] / [StickyGesture] / [AudioPlay] 1. tap
  received` log fires; move the element → drag works. Create + move
  a sticky, an image, an audio clip. Tapping empty space still
  deselects; text / sticky tools still create on an empty tap;
  tapping a text element still enters edit mode. Lasso drag-select
  still works; Pencil inking still works in inking modes. The
  `[Renderer-hit]` / `[TextCatcher]` diagnostics stay in for this
  verification pass — remove them in a separate commit once
  confirmed.

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
  - *Wrapping each overlay host in a passthrough container that
    returns nil from `hitTest` when the hit resolves to the
    container itself.* Cannot work: while an overlay's full-page
    background catcher is mounted its `_UIHostingView` claims every
    point, so the container never sees an unclaimed hit. The
    catchers had to be gated (Fix 2) — a UIKit wrapper can't
    substitute for that.
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

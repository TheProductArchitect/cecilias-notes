# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-05-20 (branch `bug-fixes`). Resolved
items should be deleted from this file, not struck through — git
history is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact, not
the engineering effort.

---

## 1. Element-tap gesture absorption — HIGH

**Symptom.** Taps on image / sticky-note / audio elements never
reach their SwiftUI element views. The views render
(`[GestureAudit] … body render` logs fire) but the
`[ImageGesture] / [StickyGesture] / [AudioPlay] 1. tap received`
logs never fire. Images can't be selected; the audio play button
doesn't respond.

**Tried and failed.** Modifier-order patches at the element-view
level — Steps 4, 7, 7.1, 7.2, audit `42c32aa`. Each appeared to
work then regressed. A `.position → .offset` restructure of all
five element views (`91b0617`) was a wrong-layer guess and was
reverted (`c46440a`) after it also broke scrolling.

**In place now.** `TouchPathLogger` (`33f3f42`) — observe-only,
pass-through `UITapGestureRecognizer`s installed across the full
touch path: UIWindow → editor root → scroll view → per-page
`PageRenderer` → PKCanvasView → image/sticky/audio overlay hosts.
Tapping an element and reading the `[TouchPath]` sequence shows
which layer the touch dies at.

**Evidence so far.** Device logs localise the absorber to the
`PageRenderer` layer — the touch dies *before* reaching the element
overlays. Prime suspect: `mountCanvas` in `ContinuousCanvasView`
adds the `PKCanvasView` to `contentView` **after** each page's
`renderer`, so the canvas is a sibling stacked on top of every
element overlay, and its gesture recognisers consume the touch even
in `.pencilOnly` mode.

**Ruled out — do not retry.** Each of these was tried and is
disproven by the `[TouchPath]` evidence above; repeating them wastes
a cycle.
- *Element-view modifier reordering* (the order of `contentShape` /
  `gesture` / `position`). 4+ attempts. The touch never reaches the
  element view, so nothing in its modifier chain can be the cause.
- *`.position → .offset` on the element views* (`91b0617`). Wrong
  layer for the same reason, and it broke scrolling — reverted in
  `c46440a`.
- *Adding more SwiftUI gestures* (`simultaneousGesture`, gesture
  priority, `highPriorityGesture`) inside the element views — same
  wrong-layer trap.
The fix lives at `PageRenderer` / `PKCanvasView` z-order and
hit-testing, nowhere above it. First thing to check next session:
whether `canvas.isUserInteractionEnabled = viewModel.canvasIsInteractive`
is genuinely `false` in cursor / image / sticky modes when the bug
reproduces — that flag is the *existing* mitigation, so the bug
means either it isn't false when it should be, or disabling it on
the PKCanvasView isn't sufficient.

**Logging.** All `#if DEBUG`.
- `[TouchPath]` — `TouchPathLogger`. On install:
  `[TouchPath] installed logger '<label>' on <ViewType>`. On tap:
  `[TouchPath] <label> tap at <point>` where `<label>` is one of
  `1. UIWindow`, `2. editor root (CanvasHostView)`, `3. scroll view`,
  `4. page <id> renderer`, `5. PKCanvasView page <id>`,
  `6. page <id> image|sticky|audio overlay host`. The last label
  that logs is where the touch reaches; silence after it is the
  absorber (or the layer just below).
- `[GestureAudit]` — `ImageElementView` / `StickyNoteElementView`
  body-render confirmation (`… body render — elementId=…`).
- `[ImageGesture]` / `[StickyGesture]` — element-view gesture
  handlers: `1. tap received`, `1a/1b`, `2. drag`, `3. drag onEnded`,
  `4./5. resize`, `isSelected changed`, `overlay.bg tap`. These are
  the logs that currently never fire — the symptom.
- `[AudioPlay]` — `1. button tap received` on the audio play button
  (also never fires). `[AudioPlayback]` — audio load / onAppear.

**Next step.** Instrument `PageRenderer` (and the PKCanvasView's
gesture recognisers) specifically, confirm the absorber, then fix
the z-order / hit-testing at that layer — not at the element views.

---

## 2. Alternate app-icon swap fails on iOS 26 — MEDIUM

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

## 3. Swift 6 language mode not adopted — LOW

**State.** The project builds in Swift 5 language mode
(`SWIFT_VERSION = 5.0`). Building under `SWIFT_VERSION=6` succeeds
with **0 errors but 37 strict-concurrency warnings**.

**Why unresolved.** Several warning sites need real restructuring of
concurrency boundaries — `PDFDocument` Sendability, `AVAudioPCMBuffer`
capture in a `@Sendable` closure, captured-`var` races in the media
pickers — and touch product-sensitive audio/PDF paths. Bigger than a
focused commit.

**Logging.** None — these are build-time diagnostics, not runtime
logs. Surface them with
`xcodebuild build … SWIFT_VERSION=6 | grep ": warning:"`.

**Next step.** See `ARCHITECTURE.md` → "Swift 6 migration status"
for the full per-file warning inventory. Complete the cleanup and
flip `SWIFT_VERSION` to `6.0` as a dedicated commit.

---

## 4. "Publishing changes from within view updates" warnings — LOW

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

## 5. Magnetic page zoom — not built (deferred feature)

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

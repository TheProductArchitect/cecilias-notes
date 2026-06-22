# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-06-22 (branch `main`). Resolved items
should be deleted from this file, not struck through — git history
is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact, not
the engineering effort.

---

## 1. Swift 6 language mode not adopted — LOW

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

## 2. "Publishing changes from within view updates" warnings — LOW

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

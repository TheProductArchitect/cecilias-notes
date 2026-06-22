# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-06-22 (branch `main`). Resolved items
should be deleted from this file, not struck through — git history
is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact, not
the engineering effort.

---

## 1. Dictation start freeze (root cause, not yet eliminated) — HIGH

**Symptom.** User taps the dictation button. Logs print up through
`[Dictation] new page created id=… number=N` and stop. The app is
completely frozen — no touches register, no scrolling, no other
input. Force-quit + reinstall is the only escape (a reinstall is
required because the dirty shutdown leaves the AVAudioSession in
a state that the next launch can't recover from cleanly).

**In place now.**
  - `LectureRecorder.start` is wrapped in an 8s `withDictationTimeout`
    race (commit `947f063`). The user now sees a recoverable
    "Dictation took too long to start — iCloud may be syncing in
    the background" message instead of a frozen app.
  - `EditorViewModel.startDictationRecording` switches off `.ruler`
    before calling into RecordingSession — covers the secondary
    ruler-touch contention path even if it isn't the primary root.
  - Granular `[Lecture] start phase=…` dlog markers
    (`permissions / audioSession / engineAndFile / speechRecognition`)
    so the next freeze log tells us which phase wedged.

**Root cause (current hypothesis).** Device logs preceding the
freeze contain dozens of
`CoreData: debug: WAL checkpoint: Database did checkpoint. Log size: 1000+`
entries — CloudKit is mid-export and holding the SQLite writer
lock while AVAudioSession's `.playAndRecord` activation also
contends for main-runloop resources. Two heavy main-thread
consumers + an audio engine that doesn't tolerate the contention
appears to deadlock. Eight seconds of timeout almost always
covers it (the export drains), but the underlying contention is
real.

**Logging.** `grep "\[Lecture\] start phase=" device.log`. If the
last marker is `engineAndFile` the wedge is inside
`startEngineAndFile`; if it's `audioSession`, AVAudioSession is
the culprit.

**Next step.** Move `LectureRecorder.startEngineAndFile` and the
`startSpeechRecognition` setup off the main actor so CloudKit's
WAL contention can't starve them. Audit AVAudioSession activation
ordering — Apple's docs say it must happen *before* engine
configuration; we do that, but the session activate hop is
synchronous and main-isolated, which is the suspected pinch
point.

---

## 2. "Remember template for new pages" leaks across notebooks — MEDIUM

**Symptom.** User taps the "remember template" toggle inside one
notebook's Add Page sheet and from then on every new page in
**every** notebook uses that template. The preference is being
applied globally instead of per-notebook.

**In place now.** Nothing — bug report received 2026-06-22.

**Hypothesis.** The toggle probably writes to a global
`UserDefaults` key rather than the per-notebook
`NotebookPreferencesStore`. The per-notebook side-channel exists
(used by `autoHideHeader`); the Add Page sheet should be routed
through it instead.

**Next step.** Audit the Add Page sheet — find the toggle binding,
trace where it persists. Move the value to
`NotebookPreferencesStore[notebookId]`; preserve the existing
JSON storage shape so on-disk preferences aren't invalidated.
Add a smoke test that two notebooks can carry independent
"remember template" settings without clobbering each other.

---

## 3. Add Page popup is cramped — LOW

**Symptom.** The Add Page sheet visually squeezes its inner
components. The user can tell the layout is fighting the sheet's
height detent.

**In place now.** Nothing — bug report received 2026-06-22.

**Next step.** Bump the sheet's `presentationDetents` to a larger
fixed height or switch to `.large`. Verify on both iPad
horizontal and iPhone portrait — the existing detent may be
sized for one device class but not the other.

---

## 4. Race-condition warning system (feature) — LOW

**Concept.** The dictation freeze, the ruler-touch lockout, and
the various "do A then B fast and the app dies" reports share a
shape: the user repeats a sequence we already know is risky.
The app could keep a registry of known-bad sequences, watch for
the user replaying one, and warn before the second-to-last step.

**Sketch.**
  - `KnownRaceRegistry`: a small `[KnownRace]` table compiled in
    at build time. Each entry has a name, a short user-visible
    description, an arming predicate (e.g. "ruler was the last
    tool active within 5s"), and a triggering predicate
    ("startDictation called").
  - `RaceWatchdog` observes the same notifications the editor /
    recording system already post (`.toolDidChange`,
    `[Dictation] startDictationRecording`, etc.), feeds them into
    the registry, and surfaces a non-blocking toast when a known
    pattern arms.
  - Telemetry: log each match locally so the user can review
    "things I've nearly hit" in Debug Settings. No remote
    reporting in v1.

**Why deferred.** Each fix above eliminates one race; the registry
is most useful for the long tail. Build the registry once we
have ≥3 concrete patterns to seed it with. Right now we have one
(`ruler → dictation`, partly mitigated) and two strong
suspicions; not enough for the registry to pay its complexity
cost.

**Next step.** After the dictation freeze root cause (issue 1)
lands, write up two more known-bad sequences from the device
logs, then build the registry against those three.

---

## 5. "Publishing changes from within view updates" warnings — LOW

**Symptom.** Up to ~12 SwiftUI "Publishing changes from within
view updates" warnings have been logged on dictation start
across the project's history. Re-baseline still pending — recent
fixes (below) may have collapsed several.

**In place now.**
  - The `navigateToPage` cluster in `startDictationRecording` —
    `refreshPages()` + `currentPageIndex` + `pendingScrollPageIndex` —
    is wrapped in `Task { @MainActor in }` (`91b0617`).
  - Three additional synchronous `objectWillChange.send()` sites
    deferred to next runloop tick because each is fired from a
    SwiftUI `Binding` setter (auto-hide pref toggle, pixel-eraser
    width slider, `applyToolToCanvas` after a colour/width/opacity
    swap). The trigger was a slider/toggle binding, so the
    synchronous send was landing inside the active view-update
    pass. `RecordingSession.state` remains deliberately undeferred
    — the dictation state machine depends on it being set
    synchronously.

**Why still open.** Above two fixes account for the deferrable
publish sites we can identify by inspection. Any remaining
warnings need device call-stacks to pin (the synchronous binding
sites above were also identified that way).

**Next step.** Re-baseline on device under the Swift 6 build to
see whether any of the 12 warnings persist. If yes, capture
`Thread.callStackSymbols` at the offending publish sites and
defer only the genuinely-safe ones (never `state`).

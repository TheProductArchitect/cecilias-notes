# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-07-08 (branch `main`).
Resolved items should be deleted from this file, not struck
through — git history is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact,
not the engineering effort.

---

## 1. Race-condition warning system (feature) — LOW

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

**Why deferred.** Each landed fix eliminates one race; the
registry is most useful for the long tail. Build it once we have
≥3 concrete patterns to seed with. Currently 1 mitigated
(`ruler → dictation`) and a handful of suspicions — not enough
to pay the registry's complexity cost.

**Next step.** Catalogue two more known-bad sequences from
device logs, then build the registry against those three.

---

## 2. "Publishing changes from within view updates" warnings — LOW

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

---

## 3. Something un-deletes soft-deleted rows on device — MEDIUM

**Symptom.** A 2026-07-07 device log showed six specific
`TextContent`/`PageElement` rows flipping `isDeleted` back to
`false` repeatedly — with CloudKit DB sync switched OFF in
Settings, so the reverter is local, not a cloud echo.

**In place now.** The visible damage is contained:
`reconcileSoftDeleteFlags()` fixes each row at most once per
session (`7a0a2e4`), so the sweep no longer loops (its own save
re-fired `NSPersistentStoreRemoteChange` and rescheduled itself
every 2 s). A row that reverts AFTER its one fix logs
`REVERTED after an earlier fix this session — leaving it alone;
find what is un-deleting this row`.

**Why still open.** The guard stops the churn but the underlying
writer is unidentified. Candidates: an importer merge that
rebuilds elements without carrying `isDeleted`, or a relationship
touch that resurrects tombstoned children on save.

**Next step.** Collect the next device log; the warn-once line
names the exact row + moment. Then breakpoint
`willSave`/`didSave` on that row's ID and read the stack.

---

## 4. Submitted binary lags the crash fixes — MEDIUM (process)

**Symptom.** App Store review crashed the app twice. Xcode
Organizer has the reports (device class iPad16,8, iPadOS 26.5):
build 2.1(1) — SIGTRAP in the audio tap closures on Voice
note/dictation (MainActor-isolated closure invoked on AVFAudio's
queue); builds 2.1(1)+2.1(3) — SIGABRT re-presenting
`UIColorPickerViewController` after eyedropper use inside the
tool-palette popover.

**In place now.** Both root causes are fixed in `main` (tap
closures made nonisolated on 2026-07-06 in `d360d2b`; color
picker moved to a UIKit top-VC presenter). But build 2.1(3) was
compiled BEFORE `d360d2b`, so the tap-closure trap almost
certainly still exists in the latest submitted binary.

**Next step.** Bump the build number, archive from current
`main`, and resubmit. Any pre-`d360d2b` binary will keep
crashing review on microphone use no matter what else changes.

---

## 5. Crash "post dictation and summary" (v3.0 report) — HIGH

**Symptom.** User reports the app crashed after a dictation
finished and the summary appeared, on a v3.0 build. No crash
report is in Organizer yet (devices offline; Organizer sync
lags), so the exact frame is unconfirmed.

**Fixed candidates (2026-07-09).** Full audit of everything that
runs in that window found two real defects, both fixed:

1. *Poisoned geometry from the summary prepend.* An element
   sitting below 92% page height made `0.92 - normalizedY`
   negative, and a zero page height made the measured height
   infinite — `prependSummary` wrote either straight into
   `normalizedHeight`, corrupting every later render of the
   block. Now clamped; `MeetingSummaryCommitTests` locks it in.
2. *Deleted-instance renders after the duplicate purge.* The
   debounced sweep fires ~2 s after any save burst — exactly the
   finalize→structure→summary burst of a dictation stop — and
   deleted stale duplicate rows WITHOUT telling the element
   overlays, which fetch manually (not `@Query`). They kept
   rendering the deleted `PageElement` instances; property access
   on a deleted SwiftData model traps. `purgeDuplicateRows` now
   posts every element-overlay refresh notification whenever it
   actually deletes rows.

**To confirm the true frame.** On the iPad: Settings → Privacy &
Security → Analytics & Improvements → Analytics Data → search
"CeciliasNotes" → share the newest `.ips`. Or connect the iPad
and let Xcode's Organizer sync. If the log shows jetsam
(EXC_RESOURCE / memory), the suspect shifts to model-inference
memory pressure during summarization, not a code defect.

**Known non-crash limitation in the same window.** If the user
is actively editing the transcript block when the summary lands
(~5–20 s after stop), the editor deliberately doesn't reload
mid-edit, and the user's subsequent persist overwrites the
summary — silent loss, not a crash. Revisit if reported.

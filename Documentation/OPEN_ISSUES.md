# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-07-18 (branch `main`).
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
fixes (below) may have collapsed several. A 2026-07-10 device
log shows one firing during page scroll (amid `TextCatcher
onAppear` lines), so at least one site is on the editor
scroll/mount path, not the dictation path. **2026-07-18
re-check:** still firing ~once per overlay mount during scroll
(device log: after `TextCatcher onAppear` and
`AudioElementStripContent.onAppear` lines). The audio strip's
own publishes are already deferred a tick, so the remaining
publisher is another member of the overlay mount transaction —
unattributed; candidates are the active-page/overlay-input
publishes on the mount path. Each occurrence is a re-entrant
render pass mid-scroll, so this is also a (minor) scroll-feel
item.

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
A 2026-07-10 device log adds a **Notebook** row to the pattern:
`[Storage] reconcileSoftDelete notebook id=18FC7E35 — restored
isDeleted (CloudKit echo)` — again with sync disabled at launch
(`cloudKitDatabase: .none` in the same log), so the "(CloudKit
echo)" attribution in that log line is wrong and misleading;
the writer is local and now touches Notebook rows too.

A second 2026-07-10 capture showed the worst consequence yet: a
**Page** row (`F157C5C8`) flapped in and out of the editor's
fetched page list mid-session (9 pages → 8 → 9 across consecutive
host rebuilds) with neither the purge nor the reconcile sweep
logging anything — so the flapper is a third, still-silent
writer. Every flap used to tear down and rebuild ALL page hosts
(the freeze); the editor now reconciles hosts incrementally and
logs `[Hosts] reconcile added=… removed=…` naming the exact page
ids, which is the tripwire for identifying the writer.

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
picker moved to a UIKit top-VC presenter on 2026-07-09).

**Next step (updated 2026-07-10).** Version 3.0 (3) was
submitted with the tap-closure fixes, but it PREDATES the
2026-07-09/10 work: the color-picker eyedropper fix, the
post-dictation hardening, the four-source ANR pass, and the
scroll/ink/dictation + three-finger-undo fixes. The next archive
from current `main` picks all of those up — cut it before the
next review round.

---

## 5. Pencil "shadow" lingers briefly after pen lift — LOW
 
**Symptom (2026-07-12).** "The pen shadow is a bit slow — I can
still see the shadow sometimes after lifting the pen." The app
draws no custom pen shadow; candidates are the system Pencil
hover preview or PencilKit's wet-ink/predicted-stroke layer
lagging its swap to the committed render under load.

**Identified (2026-07-12 screenshot).** It is the Apple Pencil
Pro HOVER TIP SHADOW — an OS-composited hardware feature that
shows a realistic pencil-tip shadow whenever the Pencil is within
hover range (~12 mm). Not app-drawn; persisting after "lift" is
expected while the tip stays near the glass.

**Next step.** Compare tracking in Apple Notes. Identical lag →
system behaviour, close this entry. Notably snappier in Notes →
our `CeciliasNotesPKCanvasView` hover-recogniser rejection (added
for the stroke-shift bug) is degrading hover tracking, and that
tradeoff needs revisiting (scope the rejection to the layout
side-effect instead of the whole recogniser).

---

## 6. Crash "post dictation and summary" (v3.0 report) — HIGH

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

---

## 7. Notebook open mounts pages it immediately unmounts — LOW

**Symptom.** 2026-07-18 device log: opening a notebook whose
resume page is deep in the document mounts + stroke-decodes pages
0–7 from offset 0, then unmounts all of them when the resume-page
jump lands. One-time wasted decode/mount work per open — part of
the "still a bit laggy" feel on open, bounded by the mid-scroll
canvas cap.

**Next step.** Apply the resume offset BEFORE the first
membership pass (seed the scroll offset in `makeUIView` /
first layout instead of jumping after the initial mount pass).

---

## 8. Stroke undo history dies when a page's canvas unmounts — LOW (accepted)

**Symptom.** Undo/redo for strokes is scoped per page canvas
(deliberate — a shared window manager interleaved pages). The
membership engine unmounts canvases outside the keep-band, and
the page's `UndoManager` dies with the canvas: scroll far away
and back, and undo/redo for that page starts empty.

**Why accepted.** Reusing a manager across remounts leaves
entries targeting dead canvas instances — the "undo button lit,
tap does nothing" bug class the per-canvas design eliminated.
The active page's canvas never unmounts while the user is on it,
so in-place work always has its history; only leave-and-return
loses it. Documented in ROBUSTNESS §3. Revisit only if users
report it in practice (the 2026-07-18 undo reports were the
button-state poll race — fixed — not this).

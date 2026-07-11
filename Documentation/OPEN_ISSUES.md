# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-07-10 (branch `main`).
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
scroll/mount path, not the dictation path.

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

## 5. Editor freeze after opening a notebook — HIGH (active)

**Symptom.** Device freezes ~seconds after opening a specific
notebook (id `75784527`, 9 pages). Reproduced across three
capture rounds on 2026-07-10/11. Every session ends with a
force-kill (each next launch logs `previous shutdown was DIRTY`).

**Fixed so far (each round shrank the storm, none ended it):**
main-thread `MCSession.send` on stale DTLS links; thumbnail keys
fingerprinting stroke bytes (2× multi-MB main-actor blob reads
per page per save); `StrokeCache` prewarm blob reads on main;
`shouldOCR` full-blob reads per page per `refreshAll()`; full
host teardown+rebuild on any page-list change (now incremental).
The 2026-07-11 12:35 build (all fixes in) still froze — but the
main-thread DB faults dropped from continuous to 48 samples in
12 s, so the remaining cause is likely NOT SQLite volume.

**Signature in the 07-11 capture.** After ONE card tap: three
consecutive full editor mounts (all pages' overlay `onAppear` +
all canvases torn down — `handwritingd` invalidation bursts)
with page `F157C5C8` flapping in/out between them, and no
`[Hosts] reconcile` log — meaning the whole canvas representable
(fresh coordinator) is being recreated, i.e. view-identity churn
ABOVE the host diff, possibly a livelock (main busy, not
blocked — the runloop-ack watchdog may never fire for this).

**Diagnostics now in place (2026-07-11).** The next capture
answers this conclusively:
  - `MainThreadWatchdog` DEBUG builds now dump THE MAIN THREAD'S
    stack at hang time (SIGPROF handler + `backtrace()`; the
    watchdog symbolicates and prints it).
  - Lifecycle logs: `[Editor] viewModel INIT/DEINIT`,
    `[Hosts] makeUIView — fresh coordinator`, `[Hosts] FULL
    rebuild`, `[Hosts] reconcile added=…removed=…`,
    `[Canvas] mount/unmount`, `[Overlays] mount/unmount`.
  - Multipeer reconnect now backs off exponentially (5 s → 5 min)
    so the DTLS stderr storm stops drowning captures.

**2026-07-11 12:55 capture (forensics build) — livelock
confirmed.** One `viewModel INIT`, one `makeUIView` (no identity
churn this run), NO watchdog dump (runloop still ticking) — but
the `[Canvas]`/`[Overlays]` logs caught the loop: mass-mount of
all 9 pages' canvases + overlay trees, immediate mass-unmount of
idx 1–7, remount idx 1, … The user reported "stuck no matter
what — just scrolling". Two membership defects fixed in response:
  - mount band == unmount threshold → border pages flipped every
    pass; now hysteresis (a host survives until it drifts a full
    extra viewport past its band);
  - overlays unmounted for every non-active page on every at-rest
    pass → now sticky while within the keep band.
Also fixed: `considerAutoConnect` invited a zombie peer on every
Bonjour `foundPeer` refresh, bypassing the reconnect backoff —
each invite = ~30 s of in-process DTLS handshake retries, which
is the "Failed to send a DTLS packet" wall in every capture. Both
invite paths now share one backoff gate.

**Suspected compounding factor while attached to Xcode:** the
DTLS storm writes stderr hundreds of times per second; the debug
console pipe applies backpressure, and `dlog` fflushes stdout on
the main thread — console saturation can itself stall main.

**2026-07-11 13:05 capture (hysteresis build) — livelock GONE.**
Whole-session mount churn collapsed to 7 canvas mounts / 5
unmounts (was continuous); main-thread I/O faults down to 10, all
inside one second at launch; DTLS spam down ~5×. Two residuals
found in the `[Membership]` trace and fixed:
  - mid-scroll, ALL canvas mounts were deferred to scroll rest —
    a fast sweep showed blank paper the whole way (reads as
    "stuck"), then the rest flush mounted every crossed page in
    one burst (7 mounts → 5 unmounts spike). Now: one synchronous
    mount per membership pass for a page intersecting the raw
    viewport; deferred queues re-check the band at mount time and
    drop pages that scrolled away.

**2026-07-11 13:26 capture — scroll healthy; new offender found.**
Mid-scroll incremental mounts behave (counts grow smoothly, no
churn, no watchdog dump). The unified log exposed a fresh storm:
`ModelBundle: Creating … com.apple.fm.language.instruct_3b` ×201
in a 16-second session (~12/s) — every `IntelligenceService
.canRun` check read `SystemLanguageModel.default.availability`,
which instantiates + verifies the 3B model bundle (NSBundle disk
I/O on main + an eligibility-observer register/deregister cycle
per read), and `canRun` is consulted from SwiftUI view bodies
(notebook cards, header, toolbar) and every save tick. Now cached
with a 60 s TTL. This also accounts for the recurring
`-[NSBundle bundleIdentifier]` main-thread I/O faults across ALL
captures.

**2026-07-11 13:47 capture — every in-app metric healthy, freeze
persists.** Scroll mounts incremental, no churn, faults down to
12, ModelBundle creations 201→14 (remaining direct readers now
routed through `FMAvailabilityCache`). The capture shows UIEvents
being DELIVERED to the window right up to the end, then the log
simply stops — across all six captures the freeze itself emits
nothing: no watchdog dump, no burst, process alive. Working
hypothesis: main keeps running and this is a TOUCH-DELIVERY
failure (gesture-recognizer wedge, invisible hit-testing blocker,
or presentation-layer scrim), which no main-thread instrument can
see.

**ROOT CAUSE FOUND (2026-07-11, device `.ips` 13:52).** SIGTRAP
on thread `com.apple.SwiftUI.AsyncRenderer` inside
`closure #1 in Color.init(light:dark:)`
(`CeciliasNotesColors.swift`): the `UIColor(dynamicProvider:)`
closure silently inherited @MainActor under
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and UIKit resolves
dynamic colors on SwiftUI's async render thread WHILE HOLDING the
render-graph lock. The same report shows the main thread blocked
on that very lock inside `touchesBegan → EventBindingBridge.send
→ _MovableLockLock`. Mechanism of the "silent freeze": attached
to Xcode, the trap suspends the process in lldb with the lock
held — every touch wedges, nothing logs, the watchdog is
suspended too; detached, it's an instant crash. Same defect
family as the audio-tap closures that crashed App Store review.
Fix landed: provider closures are `@Sendable` over pre-resolved
platform colors (both UIKit and AppKit branches).

**Verification pending:** user re-run (attached + detached).
Once confirmed dead, delete this entry and strip the
`[Membership]`/`[Canvas]`/`[Overlays]` forensics logs (keep the
watchdog dump). Note: `knowledgeconstructiond` /
`spotlightknowledged` CPU-resource `.ips` files from the same
device are system daemons churning on Spotlight donations —
worth a look at donation volume if they recur.

---

## 6. Phantom undo — strokes revert without tapping undo — HIGH

**Symptom.** Recurred 2026-07-11 on the build with
`editingInteractionConfiguration = .none` (which killed the
system three-finger-swipe undo), so that gesture was not the only
source.

**Candidate families.**
  1. A real `undoManager.undo()` call: Pencil squeeze/double-tap
     action mapped to undo, or R2 (single `viewModel.canvasView`
     pointer targeting the WRONG PAGE's canvas when the user
     scrolled mid-stroke — the undo "fires" on a page the user
     isn't looking at, and the visible page's revert comes from a
     reload).
  2. Data-level stroke loss that only reads as undo: issue #3's
     un-deleter, the duplicate purge's tombstone-wins deleting a
     LIVE stroke row, or a stale drawing apply racing a save.

**Primary-suspect fix (2026-07-11).** The canvas-only opt-out had
a hole: the per-page overlay hosts cover the FULL page
(TextCatcher is a page-sized background catcher), still honoured
the system editing-interaction gestures, and those land on the
SHARED window undo manager where PencilKit registers strokes — a
multi-finger scroll over an overlay region still fired system
undo. Overlay + template hosts now use
`NoSystemUndoHostingController` (`editingInteractionConfiguration
= .none`).

**Forensics in place (2026-07-11).** DEBUG builds log:
  - `[Undo] will UNDO/REDO — caller stack:` for every undo any
    manager performs (installed in `EditorViewModel.init`);
  - `[Canvas] drawing APPLIED (mount decode | reload cache |
    reload fetch | reload EMPTY)` with stroke counts for every
    non-user canvas drawing assignment.

**Next step.** Reproduce with the console open. A revert WITH a
matching `[Undo]` line → read the stack, fix the caller. A revert
WITHOUT one → compare the `strokes=` counts in the nearest
`[Canvas] drawing APPLIED` line against what was on screen; that
names the stale-data path.

---

## 7. Crash "post dictation and summary" (v3.0 report) — HIGH

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

# Open issues — unresolved

Status tracker for bugs and gaps that are **known but not yet
fixed**. Last reviewed 2026-06-22 (branch `main`). Resolved items
should be deleted from this file, not struck through — git history
is the archive.

Each entry: what's wrong, what's been tried, what's in place now,
and the next concrete step. Severity is the user-facing impact, not
the engineering effort.

---

## 1. "Publishing changes from within view updates" warnings — LOW

**Symptom.** Up to ~12 SwiftUI "Publishing changes from within view
updates" warnings have been logged on dictation start across the
project's history. Re-baseline still pending — recent fixes (below)
may have collapsed several.

**In place now.**
  - The `navigateToPage` cluster in `startDictationRecording`
    (`refreshPages()` + `currentPageIndex` + `pendingScrollPageIndex`)
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
sites above were also identified that way). The signal is
SwiftUI's own runtime console line:
*"Publishing changes from within view updates is not allowed;
this will cause undefined behavior."* Correlate with the
`[Dictation]` start sequence
(`RecordingSession.startDictation entered`,
`navigateToPage — newPageId=…`, `startDictation completed`) to
see which mutations coincide.

**Next step.** Re-baseline on device under the Swift 6 build to
see whether any of the 12 warnings persist. If yes, capture
`Thread.callStackSymbols` at the offending publish sites and
defer only the genuinely-safe ones (never `state`).

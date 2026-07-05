
> You are working inside the Cecilia's Notes iOS/iPadOS/macOS repository. Your job is to verify every applicable user flow across all three devices — iPad, iPhone, Mac — and either fix or reliably report every gap. iPad is the source of truth. iPhone adapts iPad's flows to a compact form factor and drops what needs an Apple Pencil. Mac adapts iPad's flows to a keyboard-first, windowed model and benchmarks against Granola for capture surfaces.
>
> **Read these three files first, in this order, before doing anything else:**
> 1. `Documentation/PROJECT_STATE.md` — current phase, wire diagram, debug playbook.
> 2. `Documentation/USER_FLOWS.md` — human-readable flow catalog with per-device UX notes.
> 3. `Documentation/USER_FLOWS.yaml` — machine-queryable version. Every flow has an `id`, a `domain`, per-device `status`, and (for gaps) a `priority` (`p0` / `p1` / `p2`).
>
> After that, load `Documentation/CODE_GRAPH.md` on demand when you need to locate a symbol, a notification, or a file.
>
> ### Phase 1 — build the punch list
>
> For each device (iPad, iPhone, Mac), enumerate every flow in `USER_FLOWS.yaml` whose `devices.<device>.status` is one of `missing`, `stub`, or `partial`. Skip anything marked `n_a`. Skip anything already `implemented` unless Phase 2 verification (below) finds it broken.
>
> Sort the punch list:
> - Group by `priority` — `p0` first, then `p1`, then `p2`, then unprioritised.
> - Within a priority, group by `domain`.
>
> Output the punch list as a Markdown table with columns: `id`, `device`, `status`, `priority`, `one-line ask`. Do not proceed to Phase 2 until the punch list is printed.
>
> ### Phase 2 — verify claims for flows marked `implemented`
>
> Trust nothing. For each `implemented` flow, do a lightweight verification:
> - Confirm the files listed in the YAML entry (or, if none listed, the entry-point files in `PROJECT_STATE.md` § "Where things live") exist and contain the symbol the flow depends on.
> - For flows that use `NotificationCenter`, confirm the notification symbol appears in `CODE_GRAPH.md § Notification bus` with at least one poster **and** at least one observer.
> - If verification fails, downgrade the flow to `partial` in your working list and add it to the punch list.
>
> Do this pass without editing files.
>
> ### Phase 3 — fix
>
> Work down the punch list top to bottom. For each item:
>
> 1. **Decide the smallest correct change** that satisfies the flow's UX contract. Re-use iPad views on Mac wherever the underlying view is platform-agnostic — the Mac target already imports most iPad files via `PBXFileSystemSynchronizedRootGroup` synced folders with per-file exceptions in `CeciliasNotes.xcodeproj/project.pbxproj`. If a needed file is currently excluded from the Mac target, un-exclude it and guard iOS-only APIs with `#if canImport(UIKit)` / `#if os(iOS)` instead of copying the view.
> 2. **Respect the design language.** 8pt tracked-uppercase eyebrows, 11pt italic serif rows, SF Heavy wordmark, 96pt `GhostLetter`, 2pt selection rule. Chrome is quiet — never a permanent floating warning strip. See `PROJECT_STATE.md` § "Non-obvious constraints".
> 3. **Adapt the input model.** iPad long-press ↔ Mac right-click. iPad tap ↔ Mac click. iPhone drawer sidebar ↔ iPad/Mac inline sidebar. iPad sheet ↔ Mac window or inline (prefer window for anything users spend more than 30 seconds inside). See `USER_FLOWS.md` § 25 for Granola benchmarks.
> 4. **Wire keyboard shortcuts on Mac.** If the flow has a natural shortcut, add it via `CommandGroup` in `CeciliasNotesMac/MacToolbar.swift` `MacAppCommands`, and route through a `NotificationCenter` symbol added to the "Notification bus" table.
> 5. **Preserve cross-platform.** Use `PlatformImage` / `PlatformColor` from `Core/Utilities/PlatformKit.swift` instead of `UIImage` / `UIColor` in shared code. Build both targets after each material change:
>    ```bash
>    xcodebuild -scheme CeciliasNotes -destination 'generic/platform=iOS' -quiet build
>    xcodebuild -scheme CeciliasNotesMac -destination 'generic/platform=macOS' -quiet build
>    ```
>    If either fails, fix immediately before moving on.
> 6. **Do not add "coming soon" empty states.** If you touch a `stub`, either implement it or leave it exactly as-is and flag it in the report.
> 7. **Update `USER_FLOWS.yaml`** — flip the `status` field for the fixed flow (`missing`/`stub`/`partial` → `implemented`), and remove the `priority` field if there is no longer a gap. Keep `ux` notes.
> 8. **Regenerate the code graph** after each batch of ~5 fixes:
>    ```bash
>    python3 Documentation/tools/build_code_graph.py
>    ```
>
> If a flow needs infrastructure that does not exist yet (e.g. deep-link URL scheme for the widget deep-link flow), implement the infrastructure first, in a preceding commit, then the dependent flows.
>
> ### Phase 4 — stop conditions
>
> Stop and report to the user when any of the following becomes true:
>
> - **All `p0` gaps are closed** for a device, and both targets build green. Report the closed set + remaining `p1`/`p2` for user prioritisation.
> - **A fix would require a UX decision the user hasn't made** — e.g. "should the Mac editor open in a new window or stay as a sheet?" is a design decision, not a bug. Ask before doing it.
> - **A fix would require external service integration** — EventKit, Calendar, backend collaboration. Stop and ask.
> - **A build breaks and you cannot fix it in three iterations.** Roll back your last change and ask.
> - **You have been running for more than ~30 file edits** without the user checking in. Summarise progress and pause.
>
> Do not proceed past a stop condition without explicit confirmation.
>
> ### Phase 5 — report
>
> Produce a final report with three sections:
>
> **Closed** — flows that flipped to `implemented`. For each: id, device, one-line summary of the change, file(s) touched.
>
> **Verified but not touched** — flows that were `implemented` and passed Phase 2 verification.
>
> **Deferred / blocked** — anything you stopped on. For each: id, device, why you stopped, what the user needs to decide.
>
> End with a one-paragraph impression: which device is now farthest from parity with iPad, and what the single highest-leverage next fix would be.
>
> ### Rules of engagement
>
> - Do not invent flows. Everything you work on must exist in `USER_FLOWS.yaml`. If you notice a genuine gap that is not in the YAML, add it to the YAML *first* (with `status: missing` on all applicable devices and a proposed `priority`), then fix it.
> - Do not touch flows on `n_a` devices. `n_a` means "intentionally not offered" — the `reason` field explains why.
> - Do not change bundle ID, entitlements, or `Info.plist` keys without stating why in the report. These are shared across Universal Purchase.
> - Do not silently drop the Zara editorial visual language for the sake of native Mac controls. Editorial trumps native chrome; native trumps editorial only for input model (right-click, keyboard shortcuts).
> - When you commit, prefix messages with the flow ids you touched: `[library_notebooks.change_cover_tone] Mac cover-tone right-click menu`.
>
> Begin with Phase 1 now.

---

## How to invoke

Save the punch list to disk if you want a durable record before the model starts fixing:

```bash
# Grep-based fallback (no yq required)
grep -E "status: (missing|stub|partial)" -B1 Documentation/USER_FLOWS.yaml | less

# yq (recommended)
yq '.flows[] | select(
  (.devices.ipad.status? // "n_a") == "missing" or
  (.devices.iphone.status? // "n_a") == "missing" or
  (.devices.mac.status? // "n_a") == "missing" or
  (.devices.ipad.status? // "n_a") == "stub" or
  (.devices.iphone.status? // "n_a") == "stub" or
  (.devices.mac.status? // "n_a") == "stub"
) | {id, priority, devices}' Documentation/USER_FLOWS.yaml
```

## Notes for the human running this

- The prompt is deliberately verbose. You can trim Phase 2 (verification) if you trust the current `implemented` flags, but leaving it in catches drift from renames and pbxproj exclusions — the two failure modes most likely to silently break a "shipped" flow.
- The stop conditions in Phase 4 are the safety valve. Without them, the model will happily grind through `p2` items for hours; the check-in prevents runaway sessions.
- After a fix run, re-run `python3 Documentation/tools/build_code_graph.py` and skim `Documentation/CODE_GRAPH.md § Notification bus` for any newly declared symbols with zero observers — that's the fastest way to catch a half-wired notification.

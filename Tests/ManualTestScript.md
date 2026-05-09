# Ink — Manual End-to-End Test Script

This document is a tester's checklist for every major user-facing
workflow in Ink. Walk through the sections in order on a fresh install
of the app. Each test is short (≤8 steps) and produces a verifiable
observable outcome. Tick the **Pass / Fail / Notes** field at the end of
each test as you go.

How to run a fresh-install pass:

1. On the device or simulator, delete the existing Ink build.
2. Reset the simulator (or sign out of iCloud on a device) so iCloud
   Drive shows no `~/iCloud/Ink/` directory.
3. Build and install fresh.
4. Walk through Section 1 first; everything else assumes onboarding has
   been completed.

Conventions used below:

- "haptic — light/medium/heavy" describes the vibration level the user
  should feel; if you can't feel one, mark a Note rather than failing
  outright (some testers turn haptics off at the OS level).
- "≤Xms" timings are eyeballed, not measured — pass unless it's clearly
  laggy.
- A test that depends on hardware (Pencil Pro squeeze) is marked
  `(N/A on supported devices only)`.

---

## Section 1 — First launch and onboarding

### Test 1.1 — Fresh install lands on onboarding
**Setup:** Delete the app, then reinstall and launch.
**Steps:**
1. Launch the app for the first time.
**Expected:**
- Onboarding cover is shown full-screen.
- Cover cannot be swipe-dismissed.
- The placeholder wordmark `i.` appears at the top of the form.
- TextField is auto-focused with the keyboard up.
**Pass / Fail / Notes:** [ ]

### Test 1.2 — Empty Continue completes silently
**Setup:** Onboarding visible, field empty.
**Steps:**
1. Tap Continue without typing anything.
**Expected:**
- Cover dismisses with a fade.
- Library appears.
- Top-left greeting slot is empty (no "library", no fallback copy).
- App icon on the home screen has not changed.
**Pass / Fail / Notes:** [ ]

### Test 1.3 — Letters-only validation: digits
**Setup:** Fresh install (or reset onboarding via UserDefaults reset).
**Steps:**
1. Type `Alex123` into the field.
2. Tap Continue.
**Expected:**
- Inline error appears: "Letters only, please."
- Field still contains `Alex123` exactly — no clearing.
- Cursor stays in the field.
- Wordmark preview shows `a.` (still using the first letter).
**Pass / Fail / Notes:** [ ]

### Test 1.4 — Letters-only validation: emoji
**Setup:** Continued from 1.3 or fresh install.
**Steps:**
1. Clear field, type `🎨Maria`.
2. Tap Continue.
**Expected:**
- Inline error: "Letters only, please."
- Field intact, cursor stays.
**Pass / Fail / Notes:** [ ]

### Test 1.5 — Diacritic name → personalising transition
**Setup:** Fresh install.
**Steps:**
1. Type `Naïve`.
2. Watch the wordmark preview update to `n.`.
3. Tap Continue.
**Expected:**
- Wordmark animates to `n.` as you type the first letter.
- "Personalising your app…" screen appears (off-white background, larger
  wordmark, single subtle pulse on the dot).
- iOS system alert appears confirming the icon change. (Apple's alert —
  cannot be styled or suppressed.)
- After dismiss, Library appears with `naïve's notes` greeting.
- Home-screen icon shows `n.` (after returning to Springboard).
**Pass / Fail / Notes:** [ ]

### Test 1.6 — Possessive grammar: trailing-s
**Setup:** Fresh install.
**Steps:**
1. Type `Chris`.
2. Tap Continue, accept the icon-change alert.
**Expected:**
- Greeting reads `chris' notes` (apostrophe only — no extra s).
- Icon switches to `c.`.
**Pass / Fail / Notes:** [ ]

### Test 1.7 — Possessive grammar: ends in "es"
**Setup:** Fresh install.
**Steps:**
1. Type `James`.
2. Continue.
**Expected:**
- Greeting reads `james' notes` (apostrophe only).
**Pass / Fail / Notes:** [ ]

### Test 1.8 — Apostrophe in name
**Setup:** Fresh install.
**Steps:**
1. Type `O'Brien`.
2. Continue.
**Expected:**
- Greeting reads `o'brien's notes` — the lowercased input plus `'s`.
- Icon switches to `o.`.
**Pass / Fail / Notes:** [ ]

### Test 1.9 — First word is taken
**Setup:** Fresh install.
**Steps:**
1. Type `Jean-Luc Picard`.
2. Continue.
**Expected:**
- Greeting reads `jean-luc's notes` — only the first whitespace-separated
  word is stored.
**Pass / Fail / Notes:** [ ]

### Test 1.10 — Non-Latin name keeps default icon
**Setup:** Fresh install.
**Steps:**
1. Type `中文`.
2. Continue.
**Expected:**
- Greeting reads `中文's notes` (lowercased — Chinese has no case).
- App icon does NOT change — Chinese characters have no Latin variant
  to fall back to. Default icon stays.
**Pass / Fail / Notes:** [ ]

### Test 1.11 — Reinstall reshows onboarding
**Setup:** Completed onboarding from a prior test.
**Steps:**
1. Delete the app.
2. Reinstall and launch.
**Expected:**
- Onboarding cover is shown again.
- No prior name is remembered.
**Pass / Fail / Notes:** [ ]

---

## Section 2 — Library

### Test 2.1 — Quick-create creates a notebook in one tap
**Setup:** Library, at the subject root.
**Steps:**
1. Tap the "+" pill in the toolbar.
**Expected:**
- A notebook is created with a playful name (e.g. "Brain Dump",
  "Scratch Pad of Doom").
- The editor opens immediately.
- The first page is blank.
- Light haptic (notebook-created) fires on creation.
**Pass / Fail / Notes:** [ ]

### Test 2.2 — Customise pill appears for fresh notebooks
**Setup:** Following 2.1, or any notebook created in the last 30s.
**Steps:**
1. Watch the top-right of the editor.
**Expected:**
- A pill with a sparkle icon and "Customise" label appears top-right.
- The pill animates in with a single subtle scale pulse on first appear
  (skipped if Reduce Motion is on).
- After 5 seconds, pill auto-dismisses with a fade.
**Pass / Fail / Notes:** [ ]

### Test 2.3 — Pill manual dismiss
**Setup:** Notebook just created, pill visible.
**Steps:**
1. Tap the X on the right side of the pill.
**Expected:**
- Pill disappears immediately (fade transition).
- No alert, no other UI changes.
**Pass / Fail / Notes:** [ ]

### Test 2.4 — Tap pill → Customise panel slides down
**Setup:** Notebook just created, pill visible.
**Steps:**
1. Tap the pill (anywhere except the X).
**Expected:**
- Pill disappears.
- Panel slides down from below the toolbar.
- Panel sections visible top-to-bottom: Name, Cover, Page Size, Page
  Template, Done.
- Tapping outside the panel dismisses it.
**Pass / Fail / Notes:** [ ]

### Test 2.5 — Live cover update behind panel
**Setup:** Customise panel open on a fresh notebook.
**Steps:**
1. Scroll the cover carousel.
2. Tap a different cover.
**Expected:**
- Selected cover gets a 3pt accent border.
- The notebook's actual cover changes immediately — visible in the
  thumbnail behind the panel and in the library card.
**Pass / Fail / Notes:** [ ]

### Test 2.6 — Live page size update
**Setup:** Customise panel open, segmented control visible.
**Steps:**
1. Tap a different segment (A4 → Letter → iPad Canvas).
**Expected:**
- The page resizes live behind the panel — paper proportions change.
- No drawings are clipped (tested on a fresh empty page).
**Pass / Fail / Notes:** [ ]

### Test 2.7 — Live template update
**Setup:** Customise panel open, template carousel visible.
**Steps:**
1. Tap each template thumbnail in turn (Blank, Lines, Grid, Dotted,
   Cornell, Music).
**Expected:**
- Each thumbnail renders its template visibly (no blank rectangles).
- Selected thumbnail gets a 3pt accent border.
- The page behind the panel re-renders with the chosen template.
**Pass / Fail / Notes:** [ ]

### Test 2.8 — Empty name in Customise panel reverts greeting
**Setup:** Personalised name set; Settings → About → Your Name field.
**Steps:**
1. Open Settings → About.
2. Find Your Name, clear the field.
3. Tap Done / focus elsewhere.
**Expected:**
- iOS system alert appears (icon revert).
- Library greeting becomes empty.
- Home-screen icon reverts to default `i.`.
**Pass / Fail / Notes:** [ ]

### Test 2.9 — Notebook context menu
**Setup:** Library with at least one notebook.
**Steps:**
1. Long-press a notebook card.
**Expected:**
- Context menu appears with: Rename, Duplicate, Pin, Delete, Move to
  Subject…, (Move to Folder… if subject has folders), Share as PDF…
- Medium haptic on long-press completion.
**Pass / Fail / Notes:** [ ]

### Test 2.10 — Pin notebook moves it to the top
**Setup:** Library with multiple notebooks.
**Steps:**
1. Long-press one notebook → Pin.
**Expected:**
- A "Pinned" strip appears at the top of the grid.
- The pinned notebook moves into that strip.
- Pin icon (or visual indicator) shows on the card.
**Pass / Fail / Notes:** [ ]

### Test 2.11 — Delete notebook with confirmation
**Setup:** Library with at least one notebook.
**Steps:**
1. Long-press a notebook → Delete.
2. Confirm the alert.
**Expected:**
- Confirmation alert appears with destructive button.
- On confirm, heavy haptic fires; notebook fades from the grid.
- Notebook is gone from Library.
**Pass / Fail / Notes:** [ ]

### Test 2.12 — Search results
**Setup:** Library with at least one notebook titled to match "abc".
**Steps:**
1. Tap the search icon in the toolbar.
2. Type `abc` in the search field.
3. Watch results.
4. Clear the field with the ⌫ X button.
**Expected:**
- Search results panel appears, showing matches grouped by type
  (Notebooks, Text Blocks, Transcriptions).
- Empty state with "Clear Search" CTA when no results.
- ⌫ button clears the field; results disappear.
**Pass / Fail / Notes:** [ ]

### Test 2.13 — Drag notebook into folder
**Setup:** Library with at least one notebook and one folder at the
same subject root.
**Steps:**
1. Drag the notebook card onto the folder card.
2. Release.
**Expected:**
- Folder accepts the drop (subtle accent ring during drag).
- Light haptic on drop.
- Notebook disappears from the root grid.
- Tapping into the folder shows the moved notebook.
**Pass / Fail / Notes:** [ ]

### Test 2.14 — Drag notebook out of folder
**Setup:** Inside a folder with a notebook.
**Steps:**
1. Long-press notebook → Move to Folder… → Out of Folder.
**Expected:**
- Notebook moves to the subject root.
- Subject root grid now shows the notebook.
**Pass / Fail / Notes:** [ ]

---

## Section 3 — Folders (Files-style browser)

### Test 3.1 — Create folder from "+" menu
**Setup:** Subject root, "+" toolbar button visible.
**Steps:**
1. Tap the "+" toolbar button.
2. Tap "New Folder".
**Expected:**
- A folder card appears in the grid named "New Folder".
- The folder enters rename mode immediately.
**Pass / Fail / Notes:** [ ]

### Test 3.2 — Tap folder navigates inside
**Setup:** Subject root with at least one folder.
**Steps:**
1. Tap the folder card.
**Expected:**
- View transitions into the folder.
- Breadcrumb bar appears at the top: `< {Subject} ▸ {Folder name}`.
- The folder name in the toolbar matches the leaf folder.
**Pass / Fail / Notes:** [ ]

### Test 3.3 — Create notebook inside folder
**Setup:** Inside a folder.
**Steps:**
1. Tap "+" → New Notebook.
**Expected:**
- Notebook is created inside the folder (not at subject root).
- Editor opens.
- After closing the editor, the notebook is visible inside the folder.
**Pass / Fail / Notes:** [ ]

### Test 3.4 — Breadcrumb tap navigates back
**Setup:** Inside a nested folder (Subject ▸ Folder A ▸ Folder B).
**Steps:**
1. Tap the `Folder A` segment in the breadcrumb.
**Expected:**
- View navigates one level up to Folder A.
- Breadcrumb leaf is now Folder A.
**Pass / Fail / Notes:** [ ]

### Test 3.5 — Folder context menu
**Setup:** Subject root with a folder.
**Steps:**
1. Long-press the folder card.
**Expected:**
- Context menu shows: Rename, Delete Folder.
- Medium haptic on long-press.
**Pass / Fail / Notes:** [ ]

### Test 3.6 — Delete non-empty folder shows two options
**Setup:** A folder containing at least one notebook or subfolder.
**Steps:**
1. Long-press → Delete Folder.
**Expected:**
- Confirmation dialog with two destructive options:
  - "Move Items & Delete Folder" — children promote up one level.
  - "Delete Folder and All Contents" — recursive soft-delete.
- Cancel button present.
**Pass / Fail / Notes:** [ ]

### Test 3.7 — Nested folders + breadcrumb
**Setup:** Subject root.
**Steps:**
1. Create Folder A, navigate in.
2. Inside, create Folder B, navigate in.
3. Create a notebook inside B.
**Expected:**
- Breadcrumb shows three segments: `< Subject ▸ A ▸ B`.
- Notebook is inside B; Folder A's grid shows only Folder B; subject
  root shows only Folder A.
**Pass / Fail / Notes:** [ ]

### Test 3.8 — Empty folder empty-state
**Setup:** A new empty folder.
**Steps:**
1. Navigate inside.
**Expected:**
- Empty state shows "{Folder name} is empty" with two CTAs:
  "New Notebook" and "New Folder".
**Pass / Fail / Notes:** [ ]

---

## Section 4 — Editor — drawing and tools

### Test 4.1 — Editor first paint
**Setup:** Tap "+" from Library.
**Steps:**
1. Wait for the editor to appear.
**Expected:**
- A blank page renders within ~1s.
- Tool palette is visible (top in portrait, right in landscape by
  default).
- Toolbar visible at the top.
- Customise pill visible top-right (≤5s).
**Pass / Fail / Notes:** [ ]

### Test 4.2 — Apple Pencil draws
**Setup:** Editor with Apple Pencil paired.
**Steps:**
1. Draw on the canvas with the Pencil.
**Expected:**
- Stroke renders smoothly with low latency.
- Pressure variation is honoured (thicker on harder press).
**Pass / Fail / Notes:** [ ]

### Test 4.3 — Finger drawing toggle ON
**Setup:** Settings → Pencil → Finger Drawing = ON. Back to editor.
**Steps:**
1. Draw with a finger.
**Expected:**
- Stroke renders.
- Two-finger gestures still pan/zoom (single-finger draws).
**Pass / Fail / Notes:** [ ]

### Test 4.4 — Finger drawing toggle OFF
**Setup:** Settings → Pencil → Finger Drawing = OFF.
**Steps:**
1. Drag a single finger across the canvas.
**Expected:**
- No stroke renders. Canvas pans/zooms instead.
- Apple Pencil still draws.
**Pass / Fail / Notes:** [ ]

### Test 4.5 — Pinch to zoom
**Setup:** Editor.
**Steps:**
1. Pinch out with two fingers.
2. Pinch in.
**Expected:**
- All pages in the continuous scroll zoom together.
- Zoom level reflected in minimap (when zoomScale > 1.5).
- Zoom range clamped between ~0.5x and ~4x.
**Pass / Fail / Notes:** [ ]

### Test 4.6 — Two-finger pan
**Setup:** Zoomed in (zoomScale > 1).
**Steps:**
1. Drag with two fingers.
**Expected:**
- Canvas pans smoothly.
- Pencil still draws when used at the same time (gesture isn't stolen).
**Pass / Fail / Notes:** [ ]

### Test 4.7 — Tool tap activates / second tap opens variant picker
**Setup:** Pen tool currently selected.
**Steps:**
1. Tap the Pen icon in the palette (already selected).
**Expected:**
- A radial / popover variant picker appears showing pen variants
  (e.g. fountain pen, brush, pencil).
**Pass / Fail / Notes:** [ ]

### Test 4.8 — Long-press pen → variant picker
**Setup:** Editor.
**Steps:**
1. Long-press the Pen icon.
**Expected:**
- Variant picker opens with the same set as the second-tap path.
- Medium haptic on long-press completion.
**Pass / Fail / Notes:** [ ]

### Test 4.9 — Tool category persistence
**Setup:** Editor, Pen tool selected with red colour, width 4.
**Steps:**
1. Switch to Marker. Set marker colour to blue, width 12.
2. Switch back to Pen.
**Expected:**
- Pen returns to red, width 4 (its prior persisted settings).
- Switch back to Marker → blue, width 12.
**Pass / Fail / Notes:** [ ]

### Test 4.10 — Eraser whole-stroke mode
**Setup:** A page with one or more strokes.
**Steps:**
1. Select Eraser → Whole Stroke mode.
2. Tap a stroke.
**Expected:**
- Entire stroke disappears.
- Medium haptic fires on erasure.
**Pass / Fail / Notes:** [ ]

### Test 4.11 — Eraser pixel mode + size slider
**Setup:** Eraser selected, pixel mode active.
**Steps:**
1. Watch the toolbar.
2. Adjust the size slider.
**Expected:**
- A size slider appears in the toolbar / variant picker.
- Eraser size updates live as the slider moves.
**Pass / Fail / Notes:** [ ]

### Test 4.12 — Erase entire page
**Setup:** A page with strokes.
**Steps:**
1. Eraser variant → "Erase Page" / equivalent.
2. Confirm the alert.
**Expected:**
- Confirmation alert.
- On confirm, all strokes on the current page are cleared.
- Heavy haptic on confirm.
**Pass / Fail / Notes:** [ ]

### Test 4.13 — Undo / Redo button states
**Setup:** Empty page.
**Steps:**
1. Verify Undo is disabled.
2. Draw a stroke.
3. Verify Undo enabled, Redo disabled.
4. Tap Undo.
5. Verify Undo disabled, Redo enabled.
6. Tap Redo.
**Expected:**
- Buttons enable / disable as the stack changes.
- Stroke disappears on Undo, returns on Redo.
**Pass / Fail / Notes:** [ ]

### Test 4.14 — Strokes autosave
**Setup:** Editor with at least one stroke.
**Steps:**
1. Wait ~2s after the last stroke (autosave debounce + buffer).
2. Force-quit the app.
3. Relaunch.
4. Open the same notebook.
**Expected:**
- Strokes are exactly as you left them.
**Pass / Fail / Notes:** [ ]

---

## Section 5 — Editor — pages

### Test 5.1 — Continuous scroll auto-add
**Setup:** Single-page notebook in the editor.
**Steps:**
1. Scroll past the bottom of the last page.
**Expected:**
- A new blank page auto-appends.
- Smooth animation, no jarring layout shift.
- Total page count in the toolbar updates.
**Pass / Fail / Notes:** [ ]

### Test 5.2 — New page uses notebook defaults
**Setup:** Notebook with default template = Lines.
**Steps:**
1. Trigger auto-add (scroll past last page).
**Expected:**
- New page renders with Lines template.
**Pass / Fail / Notes:** [ ]

### Test 5.3 — Drawings preserved across scroll
**Setup:** A notebook with strokes on page 1.
**Steps:**
1. Scroll down to page 3 (or further).
2. Scroll back up.
**Expected:**
- Page 1's strokes are intact.
- No flicker, no missing strokes.
**Pass / Fail / Notes:** [ ]

### Test 5.4 — Page strip thumbnail tap
**Setup:** Multi-page notebook, page strip visible.
**Steps:**
1. Tap a thumbnail several pages away from the current one.
**Expected:**
- Continuous scroll smoothly scrolls to that page.
- Active highlight on the strip moves to match.
**Pass / Fail / Notes:** [ ]

### Test 5.5 — Page strip context menu
**Setup:** Page strip visible.
**Steps:**
1. Long-press a thumbnail.
**Expected:**
- Menu shows: Insert Page Above, Insert Page Below, Change Template,
  Duplicate Page, Delete Page.
**Pass / Fail / Notes:** [ ]

### Test 5.6 — Per-page template change preserves drawings
**Setup:** Page 2 with strokes, template = Blank.
**Steps:**
1. Long-press page 2 thumbnail → Change Template → Lines.
**Expected:**
- Page 2 re-renders with Lines template.
- All strokes still present.
**Pass / Fail / Notes:** [ ]

### Test 5.7 — Delete page
**Setup:** Multi-page notebook.
**Steps:**
1. Long-press a thumbnail → Delete Page.
2. Confirm.
**Expected:**
- Confirmation alert.
- Page removed from notebook; remaining pages renumber.
- Medium haptic on confirm.
**Pass / Fail / Notes:** [ ]

---

## Section 6 — Toolbar behaviour

### Test 6.1 — Default position respects orientation
**Setup:** Fresh install, never moved the toolbar.
**Steps:**
1. Hold device in portrait.
2. Open editor.
3. Rotate to landscape.
**Expected:**
- Portrait: toolbar at top edge, horizontal layout.
- Landscape: toolbar at right edge, vertical layout.
**Pass / Fail / Notes:** [ ]

### Test 6.2 — Drag handle moves toolbar
**Setup:** Editor.
**Steps:**
1. Long-press the drag handle on the toolbar.
2. Drag toward the bottom edge.
3. Release.
**Expected:**
- Toolbar follows finger.
- On release, snaps to the nearest edge.
**Pass / Fail / Notes:** [ ]

### Test 6.3 — Edge snap changes layout
**Setup:** Toolbar at top edge, horizontal layout.
**Steps:**
1. Drag handle and release near the right edge.
**Expected:**
- Toolbar snaps to right edge.
- Layout is now vertical.
**Pass / Fail / Notes:** [ ]

### Test 6.4 — Position persists per orientation
**Setup:** Toolbar moved to bottom edge in portrait.
**Steps:**
1. Rotate to landscape.
2. Note the toolbar's edge in landscape.
3. Rotate back to portrait.
**Expected:**
- Returning to portrait places the toolbar at the bottom edge again.
- Landscape position is independently remembered.
**Pass / Fail / Notes:** [ ]

### Test 6.5 — Cannot overlap home indicator
**Setup:** Editor.
**Steps:**
1. Drag toolbar all the way to the very bottom.
2. Release.
**Expected:**
- Toolbar stops above the home indicator's safe area inset.
- No overlap.
**Pass / Fail / Notes:** [ ]

---

## Section 7 — Shape recognition

### Test 7.1 — Toggle off by default
**Setup:** Fresh install.
**Steps:**
1. Open editor toolbar / settings.
**Expected:**
- Shape recognition toggle is OFF by default.
**Pass / Fail / Notes:** [ ]

### Test 7.2 — Recognise rectangle
**Setup:** Shape recognition ON.
**Steps:**
1. Draw a rough rectangle (corners can be sloppy).
2. Wait ≤1s.
**Expected:**
- Stroke snaps to a clean rectangle in the current colour and width.
- "Undo Shape" pill appears at top, accent fill, for 5s.
**Pass / Fail / Notes:** [ ]

### Test 7.3 — Recognise circle / triangle / line / arrow
**Setup:** Shape recognition ON.
**Steps:**
1. Draw a rough circle, then a triangle, then a line, then an arrow.
**Expected:**
- Each snaps to its clean form.
- Arrow renders with both barbs (one stroke, two barbs from one drag).
**Pass / Fail / Notes:** [ ]

### Test 7.4 — Squiggle is preserved
**Setup:** Shape recognition ON.
**Steps:**
1. Draw a wavy line / scribble that's not a shape.
**Expected:**
- No snap.
- The stroke stays exactly as drawn.
**Pass / Fail / Notes:** [ ]

### Test 7.5 — Undo Shape pill reverts
**Setup:** A shape just got recognised, pill is visible.
**Steps:**
1. Tap the pill.
**Expected:**
- Clean shape disappears, original rough stroke comes back.
- Pill disappears.
**Pass / Fail / Notes:** [ ]

### Test 7.6 — Toggle OFF disables snapping
**Setup:** Shape recognition OFF.
**Steps:**
1. Draw a rough rectangle.
**Expected:**
- No snap. Stroke remains as drawn.
**Pass / Fail / Notes:** [ ]

---

## Section 8 — Focus mode

### Test 8.1 — Enter focus via shortcut
**Setup:** Editor with toolbar visible.
**Steps:**
1. Press ⌘⇧F.
**Expected:**
- Toolbar fades out.
- Tool palette dims to ~30% opacity.
- Page strip hides.
- Status bar hides.
- A small "Exit Focus" pill appears top-right.
**Pass / Fail / Notes:** [ ]

### Test 8.2 — Tool palette auto-hides after 3s
**Setup:** In Focus Mode, palette dimmed but visible.
**Steps:**
1. Don't touch anything for 3+ seconds.
**Expected:**
- Palette fades fully out after ~3s of no use.
- Reappears on any interaction.
**Pass / Fail / Notes:** [ ]

### Test 8.3 — Exit pill works
**Setup:** Focus Mode on.
**Steps:**
1. Tap the exit pill.
**Expected:**
- Toolbar fades back in.
- Palette returns to full opacity.
- Status bar returns.
**Pass / Fail / Notes:** [ ]

### Test 8.4 — Two-finger long-press exits
**Setup:** Focus Mode on.
**Steps:**
1. Press and hold with two fingers anywhere on the canvas for ~0.6s.
**Expected:**
- Focus Mode exits.
**Pass / Fail / Notes:** [ ]

### Test 8.5 — Returning to Library exits focus
**Setup:** Focus Mode on, in editor.
**Steps:**
1. Tap back / press ⌘W.
**Expected:**
- Returns to Library.
- Re-opening the same notebook starts in normal (non-focus) mode.
**Pass / Fail / Notes:** [ ]

---

## Section 9 — Apple Pencil Pro squeeze

`(N/A unless tester has an Apple Pencil Pro on a supported device.)`

### Test 9.1 — Squeeze opens radial wheel
**Setup:** Editor on a supported device with Pencil Pro.
**Steps:**
1. Squeeze the Pencil.
**Expected:**
- A radial wheel appears with 8 tool segments.
- Wheel is centred on the viewport (or pencil hover point).
**Pass / Fail / Notes:** [ ]

### Test 9.2 — Highlight follows pencil
**Setup:** Wheel visible.
**Steps:**
1. Hover the pencil over different segments.
**Expected:**
- The segment under the pencil highlights.
**Pass / Fail / Notes:** [ ]

### Test 9.3 — Lift over segment selects
**Setup:** Wheel visible, pencil hovering over a segment.
**Steps:**
1. Lift the pencil away from the device.
**Expected:**
- Wheel fades.
- Selected tool becomes active.
**Pass / Fail / Notes:** [ ]

### Test 9.4 — Lift outside dismisses with no change
**Setup:** Wheel visible, pencil hovering OUTSIDE all segments.
**Steps:**
1. Lift the pencil.
**Expected:**
- Wheel dismisses.
- No tool change.
**Pass / Fail / Notes:** [ ]

### Test 9.5 — Reduced wheel in Focus Mode
**Setup:** Focus Mode on, then squeeze.
**Steps:**
1. Squeeze.
**Expected:**
- Wheel shows a reduced set (Undo, Redo, Exit Focus, etc.) — not the
  full 8.
**Pass / Fail / Notes:** [ ]

---

## Section 10 — Quick capture lock-screen widget

### Test 10.1 — Widget on lock screen
**Setup:** Lock screen with the Quick Capture widget added.
**Steps:**
1. From a fully closed app state, tap the widget.
**Expected:**
- App cold-launches.
- A new notebook is created with a playful name.
- Pen tool is active.
- A blank page is shown.
- No state restoration ran (we did not resume the prior notebook).
**Pass / Fail / Notes:** [ ]

### Test 10.2 — Widget while app is suspended
**Setup:** Widget added, app is in the app switcher with a notebook
open.
**Steps:**
1. Tap the widget.
**Expected:**
- App resumes / re-launches into a NEW quick-capture notebook (not the
  prior one).
**Pass / Fail / Notes:** [ ]

---

## Section 11 — Settings

### Test 11.1 — Settings sheet, not full-screen
**Setup:** Library.
**Steps:**
1. Tap the Settings gear.
**Expected:**
- Settings appears as a sheet (drag indicator visible at top).
- Large detent by default.
- Drag-down dismisses.
**Pass / Fail / Notes:** [ ]

### Test 11.2 — Toggles persist
**Setup:** Settings → Pencil.
**Steps:**
1. Toggle every switch.
2. Close Settings.
3. Force-quit, relaunch.
4. Reopen Settings → Pencil.
**Expected:**
- Every toggle is in the state you left it.
**Pass / Fail / Notes:** [ ]

### Test 11.3 — Finger Drawing toggle drives canvas
**Setup:** Settings → Pencil.
**Steps:**
1. Toggle Finger Drawing OFF.
2. Open editor.
3. Drag with one finger.
4. Toggle ON.
5. Drag again.
**Expected:**
- OFF → finger pans, no stroke.
- ON → finger draws.
**Pass / Fail / Notes:** [ ]

### Test 11.4 — Drawing Haptics toggle
**Setup:** Settings → Pencil → Drawing Haptics.
**Steps:**
1. Toggle ON. Draw a stroke.
2. Toggle OFF. Draw a stroke.
**Expected:**
- ON: subtle haptic during stroke.
- OFF: no haptic during stroke.
**Pass / Fail / Notes:** [ ]

### Test 11.5 — Eraser default size affects only NEW strokes
**Setup:** Settings → Pencil.
**Steps:**
1. Set the default eraser size slider to 30pt.
2. Open editor, pick the pixel eraser.
**Expected:**
- Pixel eraser starts at 30pt.
- Adjusting in the editor's toolbar does NOT change the Settings
  default for next time (until you go change Settings again).
**Pass / Fail / Notes:** [ ]

### Test 11.6 — New Pages defaults applied
**Setup:** Settings → New Pages.
**Steps:**
1. Set page size to Letter and template to Grid.
2. Library → "+" to create a new notebook.
**Expected:**
- New notebook's first page is Letter + Grid.
**Pass / Fail / Notes:** [ ]

### Test 11.7 — Audio locale picker detents
**Setup:** Settings → Audio & Transcription.
**Steps:**
1. Tap the locale picker row.
**Expected:**
- Sheet opens at medium detent.
- User can drag up to large detent.
**Pass / Fail / Notes:** [ ]

### Test 11.8 — Storage refresh + clear actions
**Setup:** Settings → Storage.
**Steps:**
1. Pull to refresh.
2. Tap "Clear Audio Files…", confirm.
3. Tap "Clear Recent Exports…", confirm.
**Expected:**
- Numbers update on refresh.
- Confirmation dialogs precede destructive actions.
- Spinner during work; numbers update on completion.
**Pass / Fail / Notes:** [ ]

### Test 11.9 — Your Name save
**Setup:** Settings → About → Your Name.
**Steps:**
1. Type `Sam` in the field.
2. Tap Done / focus elsewhere.
**Expected:**
- iOS system alert (icon switch) appears.
- Wordmark preview in the row updates to `s.`.
- Library greeting becomes `sam's notes` on next visit.
**Pass / Fail / Notes:** [ ]

### Test 11.10 — Your Name clear reverts
**Setup:** Settings → About → Your Name set to `Sam`.
**Steps:**
1. Clear the field.
2. Submit.
**Expected:**
- iOS system alert (icon revert) appears.
- Wordmark preview returns to the placeholder `i.`.
- Library greeting becomes empty.
- Home-screen icon reverts to default.
**Pass / Fail / Notes:** [ ]

### Test 11.11 — Smoothing slider and Pressure picker REMOVED (regression)
**Setup:** Settings → Pencil.
**Steps:**
1. Scroll the entire Pencil section.
**Expected:**
- No "Smoothing" slider.
- No "Pressure" picker.
- Only Double-Tap, Finger Drawing, Drawing Haptics, Hover Preview
  (if supported), Eraser default size.
**Pass / Fail / Notes:** [ ]

### Test 11.12 — Page Settings menu item REMOVED (regression)
**Setup:** Editor → ⋯ More menu.
**Steps:**
1. Open the More menu.
**Expected:**
- No "Page Settings…" item.
**Pass / Fail / Notes:** [ ]

---

## Section 12 — Export

### Test 12.1 — Export PDF flow
**Setup:** Notebook with at least 2 pages of content.
**Steps:**
1. Editor → ⋯ → Export as PDF.
2. Confirm range, tap Export.
**Expected:**
- ExportOptionsView appears.
- Range selection works (default = all pages).
- Progress bar visible during render.
- Light haptic on success.
- Share sheet presents the PDF.
**Pass / Fail / Notes:** [ ]

### Test 12.2 — Export failure surfaces a banner
**Setup:** Forced failure (e.g. invalid range / disk full simulation).
**Steps:**
1. Trigger an export that will fail.
**Expected:**
- Slide-down banner with human message ("Couldn't export the
  notebook…" or similar — never raw error codes).
**Pass / Fail / Notes:** [ ]

### Test 12.3 — Print
**Setup:** Notebook open.
**Steps:**
1. Editor → ⋯ → Print.
2. Print preview opens; cancel.
3. Force a failure (no printer available, deliberate).
**Expected:**
- Print preview opens normally.
- On failure: banner with "Couldn't prepare the document for printing."
**Pass / Fail / Notes:** [ ]

---

## Section 13 — Import / paste / media

### Test 13.1 — Paste image
**Setup:** Copy an image from Photos. Editor open.
**Steps:**
1. ⌘V (or paste menu).
**Expected:**
- Image appears on the page at a sensible size.
- Image is selected with handles for resize.
**Pass / Fail / Notes:** [ ]

### Test 13.2 — Image context menu
**Setup:** Image on the page.
**Steps:**
1. Long-press the image.
**Expected:**
- Menu shows: Add Caption, Resize, Delete.
**Pass / Fail / Notes:** [ ]

### Test 13.3 — Audio recording
**Setup:** Editor.
**Steps:**
1. Open the recording panel.
2. Tap the record button.
3. Speak for ~3 seconds.
4. Tap stop.
**Expected:**
- Medium haptic at recording start.
- Live waveform draws as you speak.
- Light haptic at stop.
- An audio pin appears on the page where you started.
**Pass / Fail / Notes:** [ ]

### Test 13.4 — Audio playback
**Setup:** A page with an audio pin.
**Steps:**
1. Tap the pin.
**Expected:**
- Audio plays from the start.
- Pin pulses gently while playing (Reduce Motion off).
- With Reduce Motion ON: pin stays static, just shows a play indicator.
**Pass / Fail / Notes:** [ ]

---

## Section 14 — iCloud sync

### Test 14.1 — Enable iCloud
**Setup:** Settings → iCloud, currently disabled.
**Steps:**
1. Toggle iCloud ON.
**Expected:**
- Status indicator shows "checking" briefly.
- Then shows "up-to-date".
**Pass / Fail / Notes:** [ ]

### Test 14.2 — Mutation triggers sync
**Setup:** iCloud ON, status idle.
**Steps:**
1. Open a notebook, draw a stroke.
2. Wait ~3s.
**Expected:**
- Status indicator shows "syncing" then "up-to-date".
- Light haptic on completion.
**Pass / Fail / Notes:** [ ]

### Test 14.3 — System-level iCloud disabled
**Setup:** Sign out of iCloud at the OS level. Reopen Ink.
**Steps:**
1. Settings → iCloud row.
**Expected:**
- Row offers "Open Settings" deep-link.
- App-level toggle is disabled / explanatory.
**Pass / Fail / Notes:** [ ]

---

## Section 15 — Errors

### Test 15.1 — Offline → human error
**Setup:** Wifi off, Cellular off.
**Steps:**
1. Trigger any networked action (iCloud sync nudge, share-extension
   that needs network).
**Expected:**
- Banner: "You're offline. Connect to the internet and try again."
- No raw NSError, no error codes.
**Pass / Fail / Notes:** [ ]

### Test 15.2 — Forced rename failure
**Setup:** Trigger a rename that will fail (deliberate).
**Steps:**
1. Long-press notebook → Rename → enter a name → submit.
**Expected:**
- Banner: "Couldn't rename notebook." (or similarly human).
- Notebook remains with its old name.
**Pass / Fail / Notes:** [ ]

### Test 15.3 — All error messages are human
**Setup:** Trigger anything that surfaces an error banner.
**Steps:**
1. Read every error banner in the app.
**Expected:**
- No NSError descriptions, no negative numeric codes, no internal jargon.
- Always actionable language ("Couldn't X. Try again.").
**Pass / Fail / Notes:** [ ]

---

## Section 16 — State restoration

### Test 16.1 — Resume into editor at last page
**Setup:** Settings → "Resume where you left off" = ON.
**Steps:**
1. Open notebook A, scroll to page 5, draw a stroke.
2. Force-quit the app.
3. Relaunch.
**Expected:**
- App opens directly into notebook A on page 5.
- The stroke is intact.
**Pass / Fail / Notes:** [ ]

### Test 16.2 — Resume disabled
**Setup:** Settings → "Resume where you left off" = OFF.
**Steps:**
1. Open notebook, draw, force-quit.
2. Relaunch.
**Expected:**
- App opens to Library, not the notebook.
**Pass / Fail / Notes:** [ ]

---

## Section 17 — Keyboard shortcuts

Test each on an external keyboard.

### Test 17.1 — ⌘N → new notebook
**Expected:** Library or editor → new notebook created with playful
name, editor opens.

### Test 17.2 — ⌘F → focus search
**Expected:** Library → search field gains focus, keyboard up.

### Test 17.3 — ⌘W → close notebook
**Expected:** Editor → returns to Library.

### Test 17.4 — ⌘Z / ⇧⌘Z → undo / redo
**Expected:** Editor → undo / redo strokes.

### Test 17.5 — ⌘⇧E → export
**Expected:** Editor → ExportOptionsView opens.

### Test 17.6 — ⌘P → print
**Expected:** Editor → print preview opens.

### Test 17.7 — Hold ⌘ → discoverability HUD
**Expected:** A floating list of all shortcuts appears while ⌘ is held.

**Pass / Fail / Notes (all of 17):** [ ]

---

## Section 18 — Accessibility

### Test 18.1 — Reduce Motion: no animations
**Setup:** iOS Settings → Accessibility → Reduce Motion ON.
**Steps:**
1. Open Ink, walk through onboarding, library, editor.
**Expected:**
- No scale / fade animations.
- Transitions are instant (or near-instant easeInOut).
- The Customise pill's pulse is suppressed.
- Audio pins do NOT pulse.
**Pass / Fail / Notes:** [ ]

### Test 18.2 — VoiceOver labels
**Setup:** VoiceOver ON.
**Steps:**
1. Swipe through every UI element on the Library and editor toolbars.
**Expected:**
- Every button has a label ("New notebook", "Settings", "Search",
  "Undo", "Redo", etc.).
- No "button button" or "image" without context.
**Pass / Fail / Notes:** [ ]

### Test 18.3 — Dynamic Type
**Setup:** iOS Settings → Display → Larger Text → second-largest size.
**Steps:**
1. Open Ink, scan every chrome surface.
**Expected:**
- Toolbar / settings / library labels scale up.
- Canvas content does NOT scale (drawings are not text).
- No clipping in Settings rows.
**Pass / Fail / Notes:** [ ]

### Test 18.4 — Increase Contrast
**Setup:** iOS Settings → Accessibility → Increase Contrast ON.
**Steps:**
1. Open Ink.
**Expected:**
- Card borders darken visibly.
- All text remains readable.
- No invisible elements.
**Pass / Fail / Notes:** [ ]

---

## Section 19 — Visual consistency (regression spot-checks)

### Test 19.1 — Pressable feedback on every button
**Steps:**
1. Touch and hold every primary button (don't release): library "+",
   toolbar icons, settings rows, panel "Done".
**Expected:**
- Visible scale-down to ~0.96 and ~5% dim while held.
- Returns to normal on release.
**Pass / Fail / Notes:** [ ]

### Test 19.2 — Hit targets ≥44pt
**Steps:**
1. Try tapping the very edge of every toolbar icon and small button.
**Expected:**
- Edge taps register reliably.
- No tiny buttons that demand precision aim.
**Pass / Fail / Notes:** [ ]

### Test 19.3 — No raw `.red` / `.black` in user-facing UI
**Steps:**
1. Eye-scan every screen.
**Expected:**
- All accent colours look like the design system tokens (subdued
  blacks, brand blue, etc.).
- No fluorescent reds or pure-black UI rectangles.
**Pass / Fail / Notes:** [ ]

### Test 19.4 — Settings typography consistent
**Steps:**
1. Visit every Settings section.
**Expected:**
- Section titles same weight / size everywhere.
- Body rows same.
- Captions / tertiary text same.
**Pass / Fail / Notes:** [ ]

### Test 19.5 — Dark mode parity
**Setup:** iOS dark mode ON.
**Steps:**
1. Visit every screen: onboarding, library, folders, editor, settings,
   export.
**Expected:**
- All chrome reads correctly on dark background.
- No light-mode surfaces shining through.
- Page templates remain visible (lines etched against dark paper).
- Picked stroke colour renders literally (white = white, not flipped).
**Pass / Fail / Notes:** [ ]

---

## Tester sign-off

| Field | Value |
| --- | --- |
| Tester | |
| Device | |
| iOS version | |
| App build | |
| Date | |
| Total tests | |
| Pass | |
| Fail | |
| N/A | |
| Notes | |

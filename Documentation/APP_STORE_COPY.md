# App Store Listing — Draft Copy

First-cut copy for App Store Connect. Tone matches the in-app
editorial voice — lowercase wherever the brand uses it,
matter-of-fact descriptions, no marketing-speak superlatives
("amazing", "best", "revolutionary").

## App Name (limit 30 chars)
```
cecilia's notes
```
*14 / 30*

## Subtitle (limit 30 chars)
```
notebook for ipad and iphone
```
*27 / 30*

## Promotional Text (limit 170 chars, updateable without app review)
```
write with apple pencil, type when you can't. organise by subject. import a pdf, ask your notes a question, generate a quiz from what you wrote.
```
*149 / 170*

## Description (limit 4000 chars)
```
cecilia's notes is an editorial-feeling notebook app for ipad and iphone. write with apple pencil, type with the keyboard, drop in a pdf or a photo, record dictation. organise notebooks by subject, jump between them from a single library home.

— write & draw
  • apple pencil with palm rejection, full pencilkit stack
  • pen, pencil, brush, marker, highlighter, crayon
  • shapes tool: rectangle, ellipse, triangle, line, arrow, star, heart, callout
  • pixel + whole-stroke eraser
  • write with finger on iphone (no pencil needed)

— organise
  • every notebook lives in a subject
  • drag-and-drop pages anywhere in the strip
  • pin notebooks, tag them, search across them
  • notebooks sync across your devices with icloud

— import
  • pdfs render as notebook pages — extract page text for search and quiz
  • photos and screenshots place at the tap location
  • share extension drops files from any app into a "shareinbox" the library picks up

— audio & dictation
  • record voice notes alongside written pages
  • transcripts on supported devices
  • apple intelligence post-processes long transcripts into headings + subheadings

— quizzes from your notes
  • multiple choice, flashcards, short answer
  • generation runs on-device via apple intelligence (when available) or mcp
  • each quiz is renameable; the source notebook stays linked

— ask your notes
  • point a question at any notebook or subject
  • answers cite the pages they came from

— made for ipad and iphone
  • full editor on ipad with apple pencil
  • compact layout on iphone with finger input
  • icloud sync keeps both in step
  • settings adapt to dark mode and your accent colour
```

## Keywords (limit 100 chars, comma-separated)
```
notes,notebook,handwriting,apple pencil,pdf,quiz,dictation,study,ipad,journal,sketch,markdown,ai
```
*108 chars — trim before submitting. drop "markdown" or "journal" to fit*

## What's New (limit 4000 chars, per-release)
For the iphone-support branch's first release:
```
— full iphone support: compact masthead, drawer sidebar, single-column editor, finger-first writing
— shapes tool: drag-to-create rectangles, ellipses, triangles, lines, arrows, stars, hearts, callouts
— drag-and-drop reorder pages anywhere in the page strip
— icloud sync banner explains exactly when sync is off (and opens settings)
— quizzes can be renamed
— pdfs preserve their original filename on import
— images stay in their actual aspect ratio when selected
— pencil pro double-tap and squeeze gestures
```

## Category
- Primary: **Productivity**
- Secondary: **Education**

## Age Rating
- **4+** — no age-restricted content. Audio recording is local;
  no chat / social / web content.

## URLs needed (you'll need to host these)
- **Support URL**: a github issues page or a static support page
- **Marketing URL**: optional — a one-pager describing the app
- **Privacy Policy URL**: REQUIRED. Even though the app collects
  nothing beyond what's needed for iCloud sync, Apple requires a
  privacy policy URL. Sample boilerplate at
  https://app-privacy-policy-generator.firebaseapp.com

## Screenshots (REQUIRED, but I can't generate these)
You must provide screenshots from real devices or the simulator.
Apple requires at least:

| Device class | Resolution | Required count |
|---|---|---|
| iPhone 6.7" / 6.9" (iPhone 17 Pro Max) | 1320×2868 | 1–10 |
| iPhone 6.1" / 6.5" (iPhone 17 / iPhone 16 Pro) | 1206×2622 | optional but recommended |
| iPad Pro 13" (M-series) | 2064×2752 | 1–10 |
| iPad Pro 11" | 1668×2388 | optional |

Suggested screen captures (one per slot):
1. Library home with a few notebooks (showing the wordmark + grid)
2. An open notebook mid-stroke with the pen tool
3. Tool palette popovers (shapes + pen colour picker)
4. A PDF-imported notebook
5. The quiz builder with a notebook selected
6. The customise panel showing template variants
7. Audio recording in flight
8. Settings → cloud showing iCloud sync status

Capture on a real device with the status bar set to clean values
(9:41 time, full battery, full signal) — use `xcrun simctl status_bar`
in the simulator.

## Submission Checklist
- [ ] Privacy manifest (`PrivacyInfo.xcprivacy`) declares the
      required-reason APIs the app uses (UserDefaults, file
      timestamps, CloudKit).
- [ ] App icon at 1024×1024 in `Assets.xcassets/AppIcon.appiconset`
      (already complete).
- [ ] All screenshots uploaded in App Store Connect.
- [ ] Description, keywords, support URL, privacy URL filled in.
- [ ] Build uploaded via Xcode → Organizer → Distribute App →
      App Store Connect.
- [ ] TestFlight pass on at least one real iPad + one real iPhone
      before pushing to App Review.

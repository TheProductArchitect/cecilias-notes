# App Store Listing — Draft Copy

First-cut copy for App Store Connect. Tone matches the in-app
editorial voice — lowercase wherever the brand uses it,
matter-of-fact descriptions, no marketing-speak superlatives
("amazing", "best", "revolutionary").

## App Name (limit 30 chars)
```
Cecilia's Notes
```
*14 / 30*

## Subtitle (limit 30 chars)
```
Write, draw, dictate notes
```
*27 / 30*

_Previously "Notebook for iPhone & iPad" — Apple App Store
review rejected this: naming "iPhone"/"iPad" in a subtitle in
Apple's own product-naming style ("X for iPhone & iPad") reads
as confusingly similar to an Apple-authored compatibility badge,
independent of whether the app actually runs on those devices.
Device support is already surfaced via the app's platform
metadata, so the subtitle doesn't need to repeat it — describe
what the app does instead._

### Mac App Store subtitle (limit 30 chars)
```
Desktop companion for notes
```
*28 / 30*

## Promotional Text (limit 170 chars, updateable without app review)
```
Write with Apple Pencil, type, or let AI agents help you. Organise by subject. Import a PDF, ask your notes a question, generate a quiz.
```
*138 / 170*

## Description (limit 4000 chars)
```
Cecilia's Notes is an editorial-feeling notebook app for iPhone, iPad, and Mac. Write with Apple Pencil on iPad, type with the keyboard everywhere, drop in a PDF or a photo, record dictation. Organise notebooks by subject, jump between them from a single library home.

Write & Draw
  • Apple Pencil with palm rejection, full PencilKit stack
  • Pen, pencil, brush, marker, highlighter, crayon
  • Shapes tool: rectangle, ellipse, triangle, line, arrow, star, heart, callout
  • Pixel + whole-stroke eraser
  • Write with finger on iPhone (no Pencil needed)

Organise
  • Every notebook lives in a subject
  • Drag-and-drop pages anywhere in the strip
  • Pin notebooks, tag them, search across them
  • Notebooks sync across your devices with iCloud

Import
  • PDFs render as notebook pages — extract page text for search and quiz
  • Photos and screenshots place at the tap location
  • Share extension drops files from any app into a "ShareInbox" the library picks up

Audio & Dictation
  • Record voice notes alongside written pages
  • Transcripts on supported devices
  • Apple Intelligence post-processes long transcripts into headings + subheadings

Quizzes From Your Notes
  • Multiple choice, flashcards, short answer
  • Generation runs on-device via Apple Intelligence (when available) or MCP
  • Each quiz is renameable; the source notebook stays linked

Ask Your Notes
  • Point a question at any notebook or subject
  • Answers cite the pages they came from

AI Agent Compatible (MCP)
  • Let AI agents on your Mac read and write to your notebooks
  • Seamless local network sync (Multipeer) for instant updates
  • Works over iCloud Drive anywhere
  • Install on your Mac via terminal: npm install -g cecilias-notes-mcp 

Personalised to You
  • Tell the app your name, and it magically becomes yours
  • The app's name and icon change dynamically to match you
  • A few delightful, hidden surprises wait on the splash screen
  • Hyper-personalised, totally private, and runs entirely on-device with no backend

Made for iPhone, iPad, and Mac
  • Full editor on iPad with Apple Pencil
  • Compact layout on iPhone with finger input
  • Mac companion for typing, review, export, and search
  • iCloud sync keeps every device in step
  • Settings adapt to dark mode and your accent colour
```

### Mac companion description (App Store Connect → macOS)
```
Cecilia's Notes for Mac is the desktop companion to your iPhone and iPad notebooks. Read handwriting from iPad, edit typed text, images, PDFs, stickies, and audio. Search, quiz, export, and ask your notes — all synced through the same iCloud library.

  • Universal Purchase — one subscription unlocks iPad, iPhone, and Mac
  • Read iPad handwriting; edit everything else on Mac
  • Import PDFs as full notebooks or append pages to the open notebook
  • Rich text editing with find-and-replace, bold/italic/colour
  • Menu-bar quick capture, Services menu, Spotlight deep links
  • Multipeer sync with a nearby iPad when iCloud is slow
```

## Keywords (limit 100 chars, comma-separated)
```
notes,notebook,handwriting,apple pencil,pdf,quiz,dictation,study,ipad,ai,mcp,agents
```
*87 / 100 chars*

## What's New (limit 4000 chars, per-release)
For version 3.0 — Mac compatibility + universal platform:
```
• Native Mac app — type, review, search, quiz, and export on the desktop
• Universal Purchase — one app unlocks iPhone, iPad, and Mac
• iPhone + iPad + Mac stay in sync through iCloud
• Read iPad handwriting on Mac; edit typed text, PDFs, images, and audio everywhere
• Local network sync (Multipeer) between iPhone, iPad, and Mac on the same Wi-Fi
• Full iPhone layout: compact masthead, drawer sidebar, finger-first writing
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
- [ ] **Two binaries**: archive `CeciliasNotes` for the iOS App Store (iPhone + iPad)
      and `CeciliasNotesMac` for the Mac App Store.
- [ ] In App Store Connect → iOS app → Pricing and Availability, enable
      **Universal Purchase** and link the macOS app record.
- [ ] iOS listing device support should show **iPhone and iPad** after
      uploading build 3+ (`TARGETED_DEVICE_FAMILY = 1,2` + iPhone orientations).
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

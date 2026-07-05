# User Flow Punch List

Generated: 2026-07-05 | Source: USER_FLOWS.yaml | **182 items**

Counts — priority: {'p0': 18, 'p1': 61, 'p2': 44, '—': 59} | device: {'ipad': 35, 'mac': 109, 'iphone': 38} | status: {'partial': 111, 'missing': 65, 'stub': 6}

---

## P0 — do soon (18 items)

| id | device | status | priority | one-line ask |
| --- | --- | --- | --- | --- |
| accessibility.shortcuts | ipad | partial | p0 | Verify/fix Hardware keyboard shortcuts |
| accessibility.shortcuts | mac | partial | p0 | Missing: ⌘F ⌘⇧F ⌘⌥S ⌘0 ⌘P ⌘⇧O ⌘⇧N ⌘K. |
| editor_ai.summarize_page | mac | missing | p0 | Portable — reuse SummarizePageView. |
| editor_audio.lecture_mode | mac | missing | p0 | Highest-priority Granola-parity feature on Mac. |
| editor_customise.cover_editor | mac | missing | p0 | Sheet with 8 tones + title field. |
| handoff.deep_link | ipad | missing | p0 | Implement Deep link URL scheme to notebook / page |
| handoff.deep_link | iphone | missing | p0 | Implement Deep link URL scheme to notebook / page |
| handoff.deep_link | mac | missing | p0 | ceciliasnotes://notebook/{id}/page/{id}. |
| library_ask.open | iphone | partial | p0 | Verify/fix Open Ask My Notes |
| library_ask.open | mac | missing | p0 | High-priority Granola-parity surface; text-only. |
| library_notebooks.change_cover_tone | mac | missing | p0 | Right-click → Change cover → 8-tone palette. |
| mac_capture.command_palette | ipad | missing | p0 | Implement Command palette (⌘K) |
| mac_capture.command_palette | mac | missing | p0 | Search subjects/notebooks/pages + actions. |
| mac_capture.global_hotkey | mac | missing | p0 | User-configurable in Settings; ⌥⌘Space default. |
| mac_capture.menu_bar_quick_capture | mac | missing | p0 | ⌥⌘Space toggles a popover — title + body, saves to Unfiled. |
| system.app_intents | ipad | missing | p0 | Implement App Intents / Shortcuts |
| system.app_intents | iphone | missing | p0 | Implement App Intents / Shortcuts |
| system.app_intents | mac | missing | p0 | New note / Open notebook / Ask my notes. |

## P1 — important (61 items)

| id | device | status | priority | one-line ask |
| --- | --- | --- | --- | --- |
| accessibility.keyboard_only | ipad | partial | p1 | Verify/fix Keyboard-only navigation |
| accessibility.keyboard_only | mac | partial | p1 | Full Tab loop through sidebar / grid / editor. |
| accessibility.trackpad_gestures | mac | partial | p1 | Add pinch-zoom on canvas. |
| accessibility.voiceover | ipad | partial | p1 | Verify/fix VoiceOver navigation of library + editor |
| accessibility.voiceover | iphone | partial | p1 | Verify/fix VoiceOver navigation of library + editor |
| accessibility.voiceover | mac | partial | p1 | Verify/fix VoiceOver navigation of library + editor |
| editor_ai.ask_about_page | iphone | partial | p1 | Verify/fix Ask about page (contextual AI) |
| editor_ai.ask_about_page | mac | missing | p1 | Implement Ask about page (contextual AI) |
| editor_ai.generate_quiz | mac | missing | p1 | Implement Generate quiz from page(s) |
| editor_audio.export_transcript | ipad | partial | p1 | Verify/fix Export transcript as text |
| editor_audio.export_transcript | iphone | partial | p1 | Verify/fix Export transcript as text |
| editor_audio.export_transcript | mac | missing | p1 | Implement Export transcript as text |
| editor_audio.scrub_transcript | mac | missing | p1 | Implement Scrub / seek transcript |
| editor_audio.voice_memo | mac | partial | p1 | Enable — Granola treats capture as first-class. |
| editor_customise.page_template | mac | missing | p1 | Implement Change page template (grid / dot / blank / lined) |
| editor_export.markdown | ipad | missing | p1 | Implement Export as Markdown (typed + transcript) |
| editor_export.markdown | iphone | missing | p1 | Implement Export as Markdown (typed + transcript) |
| editor_export.markdown | mac | missing | p1 | Big Granola-parity win. |
| editor_export.print | mac | missing | p1 | ⌘P via NSPrintOperation. |
| handoff.mac_to_ipad | ipad | partial | p1 | Verify/fix Handoff editing from Mac → iPad |
| handoff.mac_to_ipad | iphone | partial | p1 | Verify/fix Handoff editing from Mac → iPad |
| handoff.mac_to_ipad | mac | partial | p1 | Verify NSUserActivity publisher. |
| library_ask.followup | ipad | partial | p1 | Verify/fix Follow-up / conversation |
| library_ask.followup | iphone | partial | p1 | Verify/fix Follow-up / conversation |
| library_ask.followup | mac | missing | p1 | Implement Follow-up / conversation |
| library_nav.all_quizzes | mac | stub | p1 | Empty state — implement read+play, no Pencil needed. |
| library_nav.all_subjects | mac | stub | p1 | Empty state — should render full grid. |
| library_nav.recent_notebooks | mac | partial | p1 | Tracker runs; add File → Open Recent (⌘⇧O). |
| library_notebooks.delete | mac | partial | p1 | Right-click → Delete; must soft-delete. |
| library_notebooks.filter_by_tag | mac | partial | p1 | Verify/fix Filter grid by tag |
| library_notebooks.move_to_subject | mac | partial | p1 | Verify drag payload accepts internal UUIDs. |
| library_notebooks.quick_look | mac | missing | p1 | Space-bar quick-look on selected cell (Finder idiom). |
| library_notebooks.rename | mac | partial | p1 | Double-click title inline; not a sheet. |
| library_notebooks.tags_edit | mac | partial | p1 | Right-click → Tags… menu entry. |
| library_quizzes.create | mac | stub | p1 | Nothing here needs Pencil; implement. |
| library_quizzes.play | mac | stub | p1 | Replace stub (Take quiz) |
| library_search.within_notebook | ipad | partial | p1 | Verify/fix Search within a notebook |
| library_search.within_notebook | iphone | partial | p1 | Verify/fix Search within a notebook |
| library_search.within_notebook | mac | partial | p1 | ⌘F inside MacEditorView scopes to open notebook. |
| library_subjects.create | mac | partial | p1 | Add ⌘⇧N. |
| library_subjects.delete | mac | partial | p1 | NSAlert-style confirm; option to move notebooks to Unfiled. |
| mac_capture.multi_window | ipad | partial | p1 | iPadOS Stage Manager already supports it. |
| mac_capture.multi_window | mac | missing | p1 | openWindow(id:value:) with notebook id. |
| mac_capture.smart_lists | ipad | missing | p1 | Implement Sidebar smart lists (Today / This week / Untagged / Recording) |
| mac_capture.smart_lists | iphone | missing | p1 | Implement Sidebar smart lists (Today / This week / Untagged / Recording) |
| mac_capture.smart_lists | mac | missing | p1 | Implement Sidebar smart lists (Today / This week / Untagged / Recording) |
| mac_capture.templates | ipad | missing | p1 | Implement New-from-template (meeting / lecture / journal) |
| mac_capture.templates | iphone | missing | p1 | Implement New-from-template (meeting / lecture / journal) |
| mac_capture.templates | mac | missing | p1 | Seeds first page with typed scaffolding. |
| sync.conflict_resolution | ipad | partial | p1 | Verify/fix Conflict-resolution UI |
| sync.conflict_resolution | iphone | partial | p1 | Verify/fix Conflict-resolution UI |
| sync.conflict_resolution | mac | partial | p1 | Verify/fix Conflict-resolution UI |
| sync.peer_pairing | ipad | partial | p1 | Verify/fix Peer pairing / trust |
| sync.peer_pairing | iphone | partial | p1 | Verify/fix Peer pairing / trust |
| sync.peer_pairing | mac | partial | p1 | Verify/fix Peer pairing / trust |
| system.services_menu | mac | missing | p1 | 'New note from selection'. |
| system.share_extension | ipad | missing | p1 | Implement Share extension (receive text/URL from other apps) |
| system.share_extension | iphone | missing | p1 | Implement Share extension (receive text/URL from other apps) |
| widgets.deep_link | ipad | missing | p1 | Implement Widget → deep link into notebook |
| widgets.deep_link | iphone | missing | p1 | Implement Widget → deep link into notebook |
| widgets.deep_link | mac | missing | p1 | Implement Widget → deep link into notebook |

## P2 — nice to have (44 items)

| id | device | status | priority | one-line ask |
| --- | --- | --- | --- | --- |
| editor_customise.background | mac | missing | p2 | Implement Change page background colour |
| editor_export.copy_as_image | ipad | partial | p2 | Verify/fix Copy page as image to clipboard |
| editor_export.copy_as_image | iphone | partial | p2 | Verify/fix Copy page as image to clipboard |
| editor_export.copy_as_image | mac | missing | p2 | ⌘⇧C. |
| editor_highlights.shape_menu | mac | missing | p2 | Menu → Insert shape (rect / circle / arrow) for keyboard-first insert. |
| editor_media.crop | ipad | partial | p2 | Verify/fix Crop image |
| editor_media.crop | iphone | partial | p2 | Verify/fix Crop image |
| editor_media.crop | mac | missing | p2 | Implement Crop image |
| editor_open.fit_to_page | ipad | partial | p2 | Verify/fix Fit-to-page / actual size |
| editor_open.fit_to_page | iphone | partial | p2 | Verify/fix Fit-to-page / actual size |
| editor_open.fit_to_page | mac | missing | p2 | ⌘0 reset zoom. |
| editor_open.minimap_jump | iphone | partial | p2 | Verify/fix Jump to page via minimap |
| editor_open.minimap_jump | mac | missing | p2 | Implement Jump to page via minimap |
| editor_pdf.rearrange_pages | ipad | partial | p2 | Verify/fix Rearrange PDF pages |
| editor_pdf.rearrange_pages | iphone | partial | p2 | Verify/fix Rearrange PDF pages |
| editor_pdf.rearrange_pages | mac | missing | p2 | Implement Rearrange PDF pages |
| library_nav.toggle_sidebar | mac | partial | p2 | Recommend ⌘⌥S shortcut to collapse. |
| library_notebooks.duplicate | ipad | partial | p2 | Verify/fix Duplicate notebook |
| library_notebooks.duplicate | iphone | partial | p2 | Verify/fix Duplicate notebook |
| library_notebooks.duplicate | mac | missing | p2 | Implement Duplicate notebook |
| library_notebooks.pin_favorite | ipad | missing | p2 | Implement Pin / favourite notebook (top of grid) |
| library_notebooks.pin_favorite | iphone | missing | p2 | Implement Pin / favourite notebook (top of grid) |
| library_notebooks.pin_favorite | mac | missing | p2 | Implement Pin / favourite notebook (top of grid) |
| library_notebooks.reorder | mac | missing | p2 | Add .dropDestination on the grid. |
| library_search.suggestions | ipad | missing | p2 | Implement Search suggestions / recents |
| library_search.suggestions | iphone | missing | p2 | Implement Search suggestions / recents |
| library_search.suggestions | mac | missing | p2 | Implement Search suggestions / recents |
| library_trash.auto_purge | ipad | partial | p2 | Verify/fix Auto-purge after N days |
| library_trash.auto_purge | iphone | partial | p2 | Verify/fix Auto-purge after N days |
| library_trash.auto_purge | mac | partial | p2 | Verify/fix Auto-purge after N days |
| mac_capture.calendar_link | ipad | missing | p2 | Optional; Granola-style meeting notes. |
| mac_capture.calendar_link | iphone | missing | p2 | Implement Calendar-linked notebooks (EventKit) |
| mac_capture.calendar_link | mac | missing | p2 | Implement Calendar-linked notebooks (EventKit) |
| mac_capture.find_replace_text | ipad | partial | p2 | Verify/fix Find-and-replace inside text element |
| mac_capture.find_replace_text | iphone | partial | p2 | Verify/fix Find-and-replace inside text element |
| mac_capture.find_replace_text | mac | missing | p2 | ⌘F inside text editor sheet. |
| mac_capture.focus_mode | ipad | partial | p2 | Verify/fix Focus mode — hide chrome |
| mac_capture.focus_mode | mac | missing | p2 | ⌃⌘F hides sidebar + toolbar. |
| onboarding.handwriting_explainer | iphone | partial | p2 | Recommend one-line copy in step 3. |
| system.drag_out | ipad | partial | p2 | Verify/fix Drag notebook / page out to another app |
| system.drag_out | mac | partial | p2 | Verify/fix Drag notebook / page out to another app |
| system.files_provider | ipad | missing | p2 | Implement Files provider (browse notebooks from Files.app) |
| system.files_provider | iphone | missing | p2 | Implement Files provider (browse notebooks from Files.app) |
| system.files_provider | mac | missing | p2 | Implement Files provider (browse notebooks from Files.app) |

## Unprioritised (59 items)

| id | device | status | priority | one-line ask |
| --- | --- | --- | --- | --- |
| accessibility.dynamic_type | mac | partial | — | Verify/fix Dynamic Type scaling |
| accessibility.reduce_motion | mac | partial | — | Verify/fix Reduce Motion |
| editor_ai.handwriting_to_text | ipad | partial | — | Verify/fix Rewrite handwriting to typed text |
| editor_ai.handwriting_to_text | iphone | partial | — | Verify/fix Rewrite handwriting to typed text |
| editor_ai.handwriting_to_text | mac | partial | — | Verify/fix Rewrite handwriting to typed text |
| editor_audio.delete_recording | mac | partial | — | Verify/fix Delete recording |
| editor_audio.dictation | mac | partial | — | System dictation should work; verify recording pill doesn't block. |
| editor_audio.playback | mac | partial | — | Verify/fix Play back recording |
| editor_export.png | mac | partial | — | Verify/fix Export page as PNG |
| editor_export.share_sheet | mac | partial | — | NSSharingServicePicker. |
| editor_highlights.annotations | mac | partial | — | Verify/fix Free annotation notes |
| editor_highlights.highlight_text | mac | partial | — | Verify/fix Highlight text |
| editor_media.files_drop | iphone | partial | — | Verify/fix Insert via Files / drag-drop |
| editor_media.ocr | mac | partial | — | Verify Vision path on Mac. |
| editor_media.photo_library | mac | partial | — | Fall back to NSOpenPanel. |
| editor_media.transform | mac | partial | — | Verify/fix Move / resize / rotate image |
| editor_open.add_page | mac | partial | — | ⌘⇧P |
| editor_open.delete_page | mac | partial | — | Verify/fix Delete page |
| editor_open.duplicate_page | ipad | partial | — | Verify/fix Duplicate page |
| editor_open.duplicate_page | iphone | partial | — | Verify/fix Duplicate page |
| editor_open.duplicate_page | mac | partial | — | Verify/fix Duplicate page |
| editor_open.reorder_pages | mac | partial | — | Verify/fix Reorder pages in strip |
| editor_pdf.import_as_pages | mac | partial | — | Verify/fix Import PDF pages into current notebook |
| editor_text.format | mac | partial | — | Verify/fix Text formatting (bold / italic / size / colour) |
| editor_text.move_resize | mac | partial | — | Verify/fix Move / resize text element |
| editor_text.sticky_note | mac | partial | — | Verify/fix Insert sticky note |
| editor_text.text_block | mac | partial | — | Verify/fix Insert text block |
| handoff.ipad_to_mac | iphone | partial | — | Verify/fix Handoff editing from iPad → Mac |
| library_ask.enter_question | iphone | partial | — | Verify/fix Enter question |
| library_ask.enter_question | mac | missing | — | Implement Enter question |
| library_ask.grounded_answer | iphone | partial | — | Verify/fix View grounded answer with citations |
| library_ask.grounded_answer | mac | missing | — | Implement View grounded answer with citations |
| library_ask.jump_to_citation | mac | missing | — | Implement Tap citation → jump to source page |
| library_quizzes.delete | mac | stub | — | Replace stub (Delete quiz) |
| library_quizzes.history | mac | stub | — | Replace stub (View quiz history / retake) |
| library_search.spotlight | mac | partial | — | Verify Spotlight registration on Mac target. |
| library_subjects.color | mac | partial | — | Verify/fix Assign subject colour |
| library_subjects.rename | mac | partial | — | Right-click → Rename or double-click. |
| library_subjects.reorder | mac | partial | — | Verify/fix Reorder subjects |
| library_trash.empty | mac | partial | — | Confirm dialog required. |
| library_trash.restore | mac | partial | — | Right-click → Restore. |
| onboarding.rerun_from_settings | mac | partial | — | Verify key reset behaviour. |
| settings.appearance | mac | partial | — | Verify/fix Appearance (theme / contrast / motion) |
| settings.audio | mac | partial | — | Verify/fix Audio settings |
| settings.cloud | mac | partial | — | Verify/fix Cloud settings |
| settings.debug | mac | partial | — | Verify/fix Debug menu |
| settings.intelligence | mac | partial | — | Verify/fix Intelligence / AI settings |
| settings.multipeer_pairing | ipad | partial | — | Verify/fix Multipeer pairing management |
| settings.multipeer_pairing | iphone | partial | — | Verify/fix Multipeer pairing management |
| settings.multipeer_pairing | mac | partial | — | Verify/fix Multipeer pairing management |
| settings.sign_out_reset | ipad | partial | — | Verify/fix Sign out / reset iCloud |
| settings.sign_out_reset | iphone | partial | — | Verify/fix Sign out / reset iCloud |
| settings.sign_out_reset | mac | partial | — | Verify/fix Sign out / reset iCloud |
| settings.storage | mac | partial | — | Verify/fix Storage settings (used space, cache clear) |
| settings.style_guide | mac | partial | — | Verify/fix Style guide inspector |
| sync.force_resync | mac | partial | — | Verify/fix Force resync |
| system.spotlight | mac | partial | — | Verify/fix Spotlight indexing |
| widgets.home_recent | mac | partial | — | Verify/fix Home-screen widget — recent notebooks |
| widgets.standby | iphone | partial | — | Verify/fix StandBy widget (charging landscape) |


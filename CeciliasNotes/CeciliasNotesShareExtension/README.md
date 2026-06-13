# Cecilia's Notes Share Extension — one-time setup

The Swift sources, Info.plist and entitlements live in this folder so
they're committed alongside the rest of the project, but the target
itself has to be created once. The synchronized-folder project layout
means new targets aren't picked up from the file system — only new
files inside an existing target's root.

## Option A — automated (recommended)

A Ruby script does the pbxproj edit for you using the `xcodeproj`
gem (the same library CocoaPods uses; it ships with safe APIs for
target / file-reference / build-phase mutation, so this isn't a
text-edit-the-pbxproj exercise).

```sh
gem install xcodeproj          # one-time, ~5s
cd CeciliasNotes/CeciliasNotesShareExtension
ruby add-target.rb
```

The script:
1. Opens `CeciliasNotes.xcodeproj`.
2. Adds a new `app_extension` target named `CeciliasNotesShareExtension`.
3. Registers the three files in this folder (Swift, Info.plist,
   entitlements) against the target.
4. Sets the bundle id (`app.ceciliasnotes.share`), team
   (`W9559HJWN9`), deployment target (17.6), code-sign style
   (Automatic), and the entitlement file path.
5. Adds an "Embed App Extensions" copy-files phase on the host app
   so the .appex ships inside the main app bundle.
6. Adds a build-order dependency from the host app to the extension.

If anything goes wrong, restore with
`git restore CeciliasNotes/CeciliasNotes.xcodeproj/project.pbxproj`.

After it runs, open Xcode → Build (⌘B) the CeciliasNotes scheme. If
the Signing & Capabilities pane on the new target doesn't show App
Groups, click "+ Capability → App Groups" and tick
`group.app.ceciliasnotes` (already registered for the main app, so
the toggle is one click).

## Option B — manual Xcode steps

1. Open `CeciliasNotes.xcodeproj`.
2. **File → New → Target… → Share Extension**.
   - Product name: `CeciliasNotesShareExtension`
   - Bundle ID: `app.ceciliasnotes.share` (or whatever matches your
     existing app ID prefix; the wildcard provisioning profile
     should cover it).
   - Embed in: `CeciliasNotes` (the main app target).
3. When Xcode prompts to activate the new scheme, allow it.
4. **Delete** the default `ShareViewController.swift`, `Info.plist`
   and `MainInterface.storyboard` that the template generated inside
   the new target's folder.
5. Move (or drag) the four files from this folder
   (`CeciliasNotesShareExtension/`) into the new target:
   - `ShareViewController.swift`
   - `Info.plist` (set as the target's Info.plist in build settings)
   - `CeciliasNotesShareExtension.entitlements` (set as the target's
     Code Signing Entitlements)
   - `README.md` is documentation only — don't add to the target.
6. **Signing & Capabilities** on the new target:
   - Add **App Groups** capability.
   - Tick `group.app.ceciliasnotes` (already registered for the
     main app).
7. Build the extension scheme to verify it compiles.
8. Run the main app; from any other app, share a PDF or image. The
   share sheet should now list **Cecilia's Notes**. Selecting it
   drops the file into the shared app-group container at
   `<container>/ShareInbox/<uuid>.<ext>`.

## Main-app side (already wireable, not yet wired)

The main app needs to watch `ShareInbox` on launch / foreground and
present an ingest UI (PDF page picker for PDFs, image-import sheet
for images). A natural home is a new `ShareInboxWatcher` service that
mirrors the existing `CeciliasNotesFileWatcher` pattern but reads from
the app-group container instead of the iCloud ubiquity container.
The watcher should:

1. List the inbox directory on `UIApplication.didBecomeActiveNotification`.
2. For each PDF: present `PDFPagePickerSheet` against the active
   editor (or hand off to a "pick a notebook" sheet if no editor is
   open).
3. For each image: route through the existing
   `mediaInsertCoordinator.insertImage(...)` path.
4. Move the file into the iCloud Inbox or delete it after ingest so
   it isn't re-processed.

Implementation of the watcher is intentionally not in this commit —
the share extension target has to exist first.

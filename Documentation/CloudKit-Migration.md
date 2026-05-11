# CloudKit Database migration — pre-flight notes

The current iCloud sync (`CloudSyncManager.enable()`) uses **iCloud Drive
Documents** to sync notebook *file assets* (drawings, audio, media) by
moving them into the ubiquity container. The SwiftData store itself
stays local — record-level conflicts are avoided because there's only
ever one writer per device-and-store.

Phase 3 of the design doc proposes switching to **CloudKit Database**
(SwiftData ↔ CloudKit) so notebook *records* sync too, enabling
multi-device editing of the same notebook. This document captures the
preconditions because the migration is non-trivial and the schema work
is risky on this codebase's deployed stores.

## Why this isn't already enabled

`ModelContainer.inkContainer()` explicitly sets `cloudKitDatabase: .none`.
The header comment names the reason: `Folder.parentSubjectId` is
non-optional and has no inline default value, which CloudKit rejects
("all attributes must be optional or have a default"). Several other
properties across `Subject`, `Notebook`, `Page`, `TextBlock`,
`MediaAttachment`, `AudioAnnotation` have the same shape.

Adding inline defaults to existing properties is, in theory,
schema-neutral (storage signature unchanged). In practice this
codebase has hit "Cannot use staged migration with an unknown model
version" crashes when even adding new optional columns to V3 in place
— see commit `78b7942`. That's why the four per-notebook fields
(`coverTone`, `autoAddPagesOnScroll`, `lastAccessedAt`,
`totalPageCount`-equivalent) live in UserDefaults side-channels
(`CoverToneStore`, `AutoAddPagesStore`, `RecentNotebooksTracker`)
instead of on the SwiftData model.

## What needs to happen

### 1. Schema work

Make every non-optional, non-default-valued property either:
- optional (`var name: String?`), or
- inline-defaulted (`var name: String = ""`)

Models to audit: `Subject`, `Folder`, `Notebook`, `Page`, `TextBlock`,
`MediaAttachment`, `AudioAnnotation`.

Bidirectional relationships need explicit inverses. Currently the
parent → child relationships are one-way:

```swift
@Relationship(deleteRule: .cascade) var notebooks: [Notebook]   // Subject
@Relationship(deleteRule: .cascade) var pages: [Page]           // Notebook
@Relationship(deleteRule: .cascade) var textBlocks: [TextBlock] // Page
// ...etc
```

Children currently track their parent via `UUID` (e.g.
`Notebook.subjectId`, `Page.notebookId`). For CloudKit, replace those
with proper `@Relationship` properties:

```swift
// On Notebook
@Relationship(inverse: \Subject.notebooks) var subject: Subject?
```

This is the hard part. Existing notebooks have `subjectId: UUID?`
populated; they need a one-time migration to populate the new
`subject` relationship.

### 2. Schema version bump (V4)

The right route is a new `InkSchemaV4` enum with the modified models,
plus a `MigrationStage.lightweight(fromVersion: V3, toVersion: V4)` in
`InkMigrationPlan`. Per the warning in `InkSchemas.swift`, the V4
models must structurally differ from V3 to avoid duplicate-checksum
crashes — adding inline defaults and inverse relationships satisfies
that.

A custom migration step is needed to populate the new `subject`
relationship from the existing `subjectId` UUID — same for `folder`
from `folderId`, `notebook` from `notebookId` on Page, etc.

### 3. Move the four side-channel stores

`coverTone`, `autoAddPagesOnScroll`, `lastAccessedAt` (recents) and
`totalPageCount` are in UserDefaults today. UserDefaults doesn't sync
via CloudKit. Two options:

- **Move to V4 SwiftData columns.** Cleaner; sync follows for free.
  Adds to the migration's complexity.
- **Move to `NSUbiquitousKeyValueStore`.** No schema work, but
  capped at 1MB per app and 64KB per key — enough for the dictionary
  blobs today, but limits headroom.

Recommend SwiftData columns as part of the V4 migration.

### 4. Container ID + entitlements

In Xcode → Targets → Ink → Signing & Capabilities:

1. Add the **iCloud** capability.
2. Enable **CloudKit** (in addition to **iCloud Documents**).
3. Add a CloudKit container — recommended ID:
   `iCloud.<your.bundle.id>` (e.g. `iCloud.com.wave.venu.Ink`).

Generated entitlements file should include:

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.com.wave.venu.Ink</string>
</array>
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
    <string>CloudKit</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.com.wave.venu.Ink</string>
</array>
```

Then in **App Store Connect → CloudKit Dashboard**, create the
container if Xcode hasn't already. The private database is what
SwiftData uses by default — no public/shared schemas required.

### 5. Flip the configuration

In `ModelContainer.inkContainer()`:

```swift
let config = ModelConfiguration(
    schema: schema,
    url: storeURL,
    cloudKitDatabase: .private("iCloud.com.wave.venu.Ink")
)
```

Gate behind the existing `ink.icloud.sync.enabled` UserDefaults flag
so users with sync off get the local-only container.

## Why we shipped infrastructure first

This file was written when the supporting UI (Settings → iCloud
toggle, sidebar status indicator with four states, last-synced
timestamp) and `CloudSyncManager` state surface (`waitingForNetwork`,
`lastSyncedAt`) landed. The current iCloud Drive Documents sync
continues to work — the new UI just gives it a proper home and
prepares the sync-status reporting surface that CloudKit Database will
plug into when V4 lands.

## Estimated effort

- Schema V4 + migration: 2-3 days, requires real-device testing across
  devices to verify migration completes cleanly.
- Side-channel store migration: 0.5 day per store.
- Conflict resolution UI (if last-write-wins isn't acceptable):
  separate work, scope tbd.
- Testing across two physical devices with real iCloud account:
  ongoing.

This is a multi-prompt project. Don't attempt it in a single session.

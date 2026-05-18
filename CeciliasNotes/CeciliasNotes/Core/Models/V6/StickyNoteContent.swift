import Foundation
import SwiftData

/// Sticky-note content for a `PageElement` of kind `.stickyNote`.
/// Step 7 promoted this from inert (V6 schema slot) to the
/// single source of truth — the legacy `StickyNoteStore`
/// UserDefaults pipeline is gone. Position / size / rotation live
/// on the parent `PageElement` like every other primitive.
///
/// `colorVariant` is a string (`"yellow"` | `"pink"` | `"blue"` |
/// `"green"`) rather than an enum so adding palette tones later is
/// a value change, not a schema migration. The renderer maps the
/// key to the current theme's resolved colour at draw time via
/// `Theme.stickyNotePalette`.
@Model
final class StickyNoteContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    var text: String         = ""
    var colorVariant: String = "yellow"

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        text: String = "",
        colorVariant: String = "yellow",
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id           = id
        self.text         = text
        self.colorVariant = colorVariant
        self.createdAt    = createdAt
        self.updatedAt    = updatedAt
    }
}

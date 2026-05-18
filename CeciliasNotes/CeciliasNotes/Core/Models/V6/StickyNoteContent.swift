import Foundation
import SwiftData

/// Sticky-note content for a `PageElement` of kind `.stickyNote`.
/// V6 (Step 1): inert. The existing `StickyNoteStore` UserDefaults
/// pipeline keeps serving the sticky overlay until Step 7 migrates
/// onto this row.
///
/// `colorVariant` is a string ("yellow" | "pink" | "blue" | "green")
/// rather than an enum so adding palette tones later is a value
/// change, not a schema migration. The renderer maps the string to
/// the current theme's resolved colour at draw time.
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

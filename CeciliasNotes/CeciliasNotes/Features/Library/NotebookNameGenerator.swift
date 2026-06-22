import Foundation

// MARK: - NotebookNameGenerator

/// Curated playful names for new notebooks. Replaces the sterile
/// "Untitled / Untitled 2 / …" default. Picked at random; collisions
/// (the chosen name already exists) get a numeric suffix.
///
/// Used by the in-app "+" flow and by the Quick Capture lock-screen widget.
enum NotebookNameGenerator {

    /// ~35 names spanning the reasonable surface of "scratch pad" feeling
    /// without being precious. Edit freely — order doesn't matter.
    nonisolated static let names: [String] = [
        "Brain Dump",
        "Scratch Pad of Doom",
        "The Notebook Formerly Known As New",
        "Thoughts, Loose",
        "Today's Nonsense",
        "A Wild Notebook Appeared",
        "Coffee-Fueled Ideas",
        "Half-Baked",
        "Doodle Dungeon",
        "The Margins",
        "Found Notes",
        "Rough Cut",
        "Possibly Important",
        "Unsorted Genius",
        "Pen, Meet Paper",
        "Probably Nothing",
        "First Draft Energy",
        "Margin Notes",
        "Loose Threads",
        "Quick Capture",
        "Notes To Self",
        "The Idea Folder",
        "Workshop",
        "Sketchbook",
        "Backburner",
        "Inbox Zero, Sort Of",
        "Stream of Consciousness",
        "Crumpled Page",
        "The Outline",
        "Writing Room",
        "Side Quest",
        "Late Night Notes",
        "Weekend Project",
        "Misc.",
        "Working File",
    ]

    /// Returns a random playful name that doesn't collide with `existingTitles`.
    /// If the picked name is taken, appends " 2", " 3", … until unique.
    /// `existingTitles` is passed in (rather than fetched here) so the call
    /// site can choose the appropriate scope — the main app fetches all
    /// notebook titles; the widget can pass an empty set since it doesn't
    /// have access to the SwiftData store.
    nonisolated static func randomName(avoiding existingTitles: Set<String>) -> String {
        let base = names.randomElement() ?? "Untitled"
        if !existingTitles.contains(base) { return base }
        var n = 2
        while existingTitles.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }
}

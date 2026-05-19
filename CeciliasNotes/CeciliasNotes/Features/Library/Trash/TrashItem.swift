import Foundation

/// View-model wrapper for one soft-deleted record. Not a SwiftData
/// entity — `TrashService` materialises these on demand from
/// `Subject` / `Folder` / `Notebook` / `Page` / `PageElement` rows
/// whose `deletedAt` is non-nil.
///
/// Each entity type carries different display affordances (a
/// notebook needs its title, a page needs the parent notebook's
/// name + page number, an element needs the element kind + parent
/// page provenance), so the `Kind` enum holds the live SwiftData
/// model and the view derives presentation from there.
struct TrashItem: Identifiable {
    let id: UUID
    let kind: Kind
    let displayName: String
    let deletedAt: Date
    /// Provenance string — e.g. "Notebook · Physics 101" or
    /// "Page 3 · Physics 101". Renders under the display name so a
    /// user can locate the deleted item in context.
    let context: String

    enum Kind {
        case subject(Subject)
        case folder(Folder)
        case notebook(Notebook)
        case page(Page)
        case element(PageElement)
    }

    /// SF Symbol name shown on the leading edge of each trash row.
    var iconSystemName: String {
        switch kind {
        case .subject:  return "folder.badge.gearshape"
        case .folder:   return "folder"
        case .notebook: return "book.closed"
        case .page:     return "doc"
        case .element(let element):
            switch element.kind {
            case .image:      return "photo"
            case .audio:      return "waveform"
            case .stickyNote: return "note.text"
            case .text:       return "textformat"
            case .pdfPage:    return "doc.richtext"
            case .stroke:     return "scribble"
            case .shape:      return "square.on.circle"
            case .highlight:  return "highlighter"
            }
        }
    }

    /// Short label for the entity type — first line of the
    /// secondary text under `displayName`.
    var kindLabel: String {
        switch kind {
        case .subject:  return "Subject"
        case .folder:   return "Folder"
        case .notebook: return "Notebook"
        case .page:     return "Page"
        case .element(let element):
            switch element.kind {
            case .image:      return "Image"
            case .audio:      return "Audio"
            case .stickyNote: return "Sticky Note"
            case .text:       return "Text"
            case .pdfPage:    return "PDF Page"
            case .stroke:     return "Strokes"
            case .shape:      return "Shape"
            case .highlight:  return "Highlight"
            }
        }
    }
}

import Foundation

// Codable mirror of the `.inkbook` v1 JSON schema. These structs are
// the read-side contract between the iPad app and any external agent
// (currently `cecilias-notes-mcp` on macOS) that drops a `.inkbook`
// file into the synced iCloud folder. The app never writes this
// format — it only parses incoming files and converts them into
// SwiftData (`Notebook` / `Page` / `TextBlock`) via
// `CeciliasNotesParser`.
//
// Field names match the schema verbatim (snake_case) so the JSON maps
// straight onto these structs without a custom keyDecodingStrategy.

struct CeciliasNotesFile: Codable {
    let schema: String?
    let version: String
    let id: String
    let title: String
    let subject: String
    let created_at: String
    let updated_at: String
    let cover_tone: String?
    let page_template: String?
    let page_size: String?
    let agent: Agent?
    let pages: [PageNode]

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, id, title, subject, created_at, updated_at
        case cover_tone, page_template, page_size, agent, pages
    }

    struct Agent: Codable {
        let written_by: String
        let model: String?
        let tool: String
        let tool_version: String
    }

    struct PageNode: Codable {
        let id: String
        let index: Int
        let created_at: String?
        let blocks: [Block]
    }

    /// Discriminated-union block. Decoded by `type`; unknown types
    /// decode to `.unknown` and the parser skips them rather than
    /// failing the whole file.
    enum Block: Codable {
        case heading(content: String, level: Int)
        case paragraph(content: String)
        case list(style: ListStyle, items: [String])
        case code(content: String, language: String?)
        case divider
        case quote(content: String, attribution: String?)
        case callout(content: String, kind: CalloutKind)
        case unknown

        enum ListStyle: String, Codable { case bullet, numbered }
        enum CalloutKind: String, Codable { case note, warning, tip }

        private enum CodingKeys: String, CodingKey {
            case type, content, level, style, items, language
            case attribution, kind
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let type = try c.decode(String.self, forKey: .type)
            switch type {
            case "heading":
                let content = (try? c.decode(String.self, forKey: .content)) ?? ""
                let level   = (try? c.decode(Int.self,    forKey: .level))   ?? 1
                self = .heading(content: content, level: max(1, min(3, level)))
            case "paragraph":
                let content = (try? c.decode(String.self, forKey: .content)) ?? ""
                self = .paragraph(content: content)
            case "list":
                let style = (try? c.decode(ListStyle.self, forKey: .style)) ?? .bullet
                let items = (try? c.decode([String].self, forKey: .items)) ?? []
                self = .list(style: style, items: items)
            case "code":
                let content  = (try? c.decode(String.self, forKey: .content)) ?? ""
                let language =  try? c.decode(String.self, forKey: .language)
                self = .code(content: content, language: language)
            case "divider":
                self = .divider
            case "quote":
                let content     = (try? c.decode(String.self, forKey: .content)) ?? ""
                let attribution =  try? c.decode(String.self, forKey: .attribution)
                self = .quote(content: content, attribution: attribution)
            case "callout":
                let content = (try? c.decode(String.self, forKey: .content)) ?? ""
                let kind    = (try? c.decode(CalloutKind.self, forKey: .kind)) ?? .note
                self = .callout(content: content, kind: kind)
            default:
                self = .unknown
            }
        }

        // App is read-only for this format; encode is a no-op stub
        // to satisfy Codable.
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode("unknown", forKey: .type)
        }
    }
}

// MARK: - Schema-string → app-enum mappings

extension CeciliasNotesFile {

    /// Maps the schema's hyphenated tone strings onto the app's
    /// `NotebookCoverTone` cases. Returns nil for unrecognised values
    /// so the importer can fall through to `CoverToneAssigner`.
    static func coverTone(from raw: String?) -> NotebookCoverTone? {
        guard let raw else { return nil }
        switch raw {
        case "parchment":     return .parchment
        case "studio-white":  return .studioWhite
        case "ash":           return .ash
        case "coal":          return .coal
        case "midnight":      return .midnight
        case "moss":          return .moss
        case "dusk":          return .dusk
        case "ink-black":     return .inkBlack
        default:              return nil
        }
    }

    /// Maps the schema's coarse template names onto the app's flat
    /// `PageTemplate` enum. The schema deliberately exposes only six
    /// generic options; we pick a sensible representative for each.
    static func pageTemplate(from raw: String?) -> PageTemplate {
        switch raw {
        case "blank":      return .blank
        case "lined":      return .collegeRuled
        case "grid":       return .squareGrid10
        case "dot-grid":   return .dotGrid10
        case "cornell":    return .cornell
        case "music":      return .music
        default:           return .collegeRuled
        }
    }

    static func pageSize(from raw: String?) -> PageSize {
        switch raw {
        case "a4":           return .a4
        case "letter":       return .letter
        case "ipad-canvas":  return .ipadCanvas
        default:             return .a4
        }
    }
}

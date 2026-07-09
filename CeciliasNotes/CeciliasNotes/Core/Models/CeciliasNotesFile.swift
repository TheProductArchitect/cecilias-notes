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

// Marked nonisolated so the parser can decode this off the main
// actor without inheriting an isolated Codable conformance under
// SWIFT_APPROACHABLE_CONCURRENCY's default-isolation inference.
nonisolated struct CeciliasNotesFile: Codable {
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

    // MARK: - Origin (v1.2 additive)
    //
    // Device + platform where the notebook was created and last
    // edited. Round-trips through the iCloud mirror so MCP-created
    // books show the agent writer on iPhone/iPad, and iPad edits
    // show up correctly when the mirror is read back on Mac.
    let origin: Origin?

    // MARK: - Optimistic concurrency (v1.1 additive)
    //
    // The MCP's append/edit tools follow a read-modify-write loop:
    // they read the mirror, mutate, and write back to the Inbox.
    // Without a base check, an iPad edit made between read and
    // write is clobbered on import. The two optional fields below
    // are the contract the MCP uses to declare:
    //
    //   • `mcp_action` — what the writer intended:
    //       "create"  : brand-new notebook, no base check needed
    //       "append"  : appending pages to an existing notebook;
    //                   importer must reconcile against the base
    //       "replace" : explicit overwrite regardless of base
    //   • `base_updated_at` — the `updated_at` value the MCP read
    //     from the mirror before mutating. Importer compares this
    //     against the live notebook's `updatedAt`; mismatch =
    //     concurrent iPad edit = merge instead of replace.
    //
    // Older MCP versions and any non-MCP writer leave both fields
    // nil; the importer falls back to wholesale replace
    // (current-behaviour back-compat).
    let mcp_action: String?
    let base_updated_at: String?

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case version, id, title, subject, created_at, updated_at
        case cover_tone, page_template, page_size, agent, pages, origin
        case mcp_action, base_updated_at
    }

    struct Origin: Codable {
        let created_on_device: String?
        let created_on_platform: String?
        let last_modified_on_device: String?
        let last_modified_on_platform: String?
    }

    /// Parsed `mcp_action`. Unknown strings collapse to `nil`
    /// (back-compat path) so a future MCP that ships a new verb
    /// doesn't break older app builds — they fall through to
    /// wholesale replace, the same conservative default applied
    /// for files with no `mcp_action` at all.
    enum MCPAction: String {
        case create
        case append
        case replace
    }
    var parsedMCPAction: MCPAction? {
        guard let raw = mcp_action else { return nil }
        return MCPAction(rawValue: raw)
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
        /// True when the page contains Apple Pencil ink strokes.
        /// Optional + omitted-when-false so the schema stays
        /// back-compatible (a mirror written before this field
        /// existed decodes cleanly). Agents reading the mirror
        /// inspect this to tell "the user wrote with the Pencil"
        /// apart from "the page is genuinely empty."
        let has_ink: Bool?

        init(
            id: String,
            index: Int,
            created_at: String?,
            blocks: [Block],
            has_ink: Bool? = nil
        ) {
            self.id = id
            self.index = index
            self.created_at = created_at
            self.blocks = blocks
            self.has_ink = has_ink
        }
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

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .heading(let content, let level):
                try c.encode("heading",   forKey: .type)
                try c.encode(content,     forKey: .content)
                try c.encode(level,       forKey: .level)
            case .paragraph(let content):
                try c.encode("paragraph", forKey: .type)
                try c.encode(content,     forKey: .content)
            case .list(let style, let items):
                try c.encode("list",      forKey: .type)
                try c.encode(style,       forKey: .style)
                try c.encode(items,       forKey: .items)
            case .code(let content, let language):
                try c.encode("code",      forKey: .type)
                try c.encode(content,     forKey: .content)
                try c.encodeIfPresent(language, forKey: .language)
            case .divider:
                try c.encode("divider",   forKey: .type)
            case .quote(let content, let attribution):
                try c.encode("quote",     forKey: .type)
                try c.encode(content,     forKey: .content)
                try c.encodeIfPresent(attribution, forKey: .attribution)
            case .callout(let content, let kind):
                try c.encode("callout",   forKey: .type)
                try c.encode(content,     forKey: .content)
                try c.encode(kind,        forKey: .kind)
            case .unknown:
                try c.encode("unknown",   forKey: .type)
            }
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
        // Default to a blank page when the MCP didn't specify a
        // template. The previous default (`college-ruled` lines)
        // dominated AI-written content visually and made the
        // notebook feel pre-formatted even when the agent intended
        // a clean canvas. Blank reads as "AI wrote this freeform";
        // agents that want a ruled background opt in via the
        // explicit `page_template: "lined"` schema value.
        default:           return .blank
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

    // MARK: - Reverse mappings (app enum → schema string, used by exporter)

    nonisolated static func schemaString(for size: PageSize) -> String {
        switch size {
        case .a4:         return "a4"
        case .letter:     return "letter"
        case .ipadCanvas: return "ipad-canvas"
        }
    }

    /// Maps internal `PageTemplate` cases back to the six coarse
    /// schema strings. Any template not in the schema's vocabulary
    /// maps to its nearest representative.
    nonisolated static func schemaString(for template: PageTemplate) -> String {
        switch template {
        case .blank, .storyboard, .mindMap,
             .calendarWeek, .dayPlanner,
             .taskList, .habitTracker:  return "blank"
        case .collegeRuled,
             .wideRuled,
             .narrowRuled,
             .twoColumn:               return "lined"
        case .squareGrid5,
             .squareGrid10,
             .engineeringGrid:         return "grid"
        case .dotGrid5,
             .dotGrid10,
             .isoDots:                 return "dot-grid"
        case .cornell:                 return "cornell"
        case .music:                   return "music"
        }
    }

    nonisolated static func schemaString(for tone: NotebookCoverTone?) -> String? {
        guard let tone else { return nil }
        switch tone {
        case .parchment:   return "parchment"
        case .studioWhite: return "studio-white"
        case .ash:         return "ash"
        case .coal:        return "coal"
        case .midnight:    return "midnight"
        case .moss:        return "moss"
        case .dusk:        return "dusk"
        case .inkBlack:    return "ink-black"
        }
    }
}

import Foundation
#if canImport(UIKit)
import UIKit
private typealias ParserColor = UIColor
private typealias ParserFont = UIFont
#elseif canImport(AppKit)
import AppKit
private typealias ParserColor = NSColor
private typealias ParserFont = NSFont
#endif

/// Parses a `.inkbook` JSON file off disk into a structured value
/// (`CeciliasNotesFile`) and renders each block into a single
/// `NSAttributedString` per page that the existing `TextBlock`
/// rendering path can consume verbatim.
///
/// The parser does NOT touch SwiftData — that lives in
/// `CeciliasNotesImporter`. Keeping the two split means file I/O is
/// callable off the main actor while persistence stays on it.
/// Pure value work — explicitly nonisolated so detached parser
/// tasks can invoke every entry point without crossing the main
/// actor. Under `SWIFT_APPROACHABLE_CONCURRENCY`, types default
/// to main-actor isolation; the marker below opts the whole
/// namespace back out.
nonisolated enum CeciliasNotesParser {

    enum ParseError: Error {
        case invalidUTF8
        case malformedJSON(Error)
        case wrongSchema(String)
        case noPages
    }

    /// Reads + decodes the file. Pure value work — safe to call from
    /// any thread. Explicitly nonisolated so detached parser tasks
    /// can invoke it without crossing the main actor.
    nonisolated static func parse(url: URL) throws -> CeciliasNotesFile {
        // Use NSFileCoordinator: the file may live in an iCloud
        // ubiquity container and could be mid-download. Coordinated
        // reads block until the file is materialised.
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordError: NSError?
        var data: Data?
        var readError: Error?

        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do { data = try Data(contentsOf: readURL) }
            catch { readError = error }
        }
        if let coordError { throw ParseError.malformedJSON(coordError) }
        if let readError  { throw ParseError.malformedJSON(readError) }
        guard let raw = data else { throw ParseError.invalidUTF8 }

        let file: CeciliasNotesFile
        do {
            file = try JSONDecoder().decode(CeciliasNotesFile.self, from: raw)
        } catch {
            throw ParseError.malformedJSON(error)
        }

        if file.version != "1" {
            throw ParseError.wrongSchema("Unsupported version \(file.version)")
        }
        if file.pages.isEmpty { throw ParseError.noPages }
        return file
    }

    /// Renders the block list of a single page into one
    /// `NSAttributedString` ready for archiving into
    /// `TextBlock.richTextData`. Mirrors the typography in the spec —
    /// heading sizes scale with `level`, bullets/numbers are inlined
    /// into list items, dividers use a horizontal-rule glyph row,
    /// callouts use a leading emoji per kind.
    nonisolated static func renderBlocks(_ blocks: [CeciliasNotesFile.Block]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let separator = NSAttributedString(string: "\n\n")

        for block in blocks {
            let rendered = render(block)
            if rendered.length == 0 { continue }
            if out.length > 0 { out.append(separator) }
            out.append(rendered)
        }
        // Apply a wrapping-friendly paragraph style across the whole
        // rendered run. Default attributed strings don't carry an
        // explicit paragraph style, which means a single very long
        // unbroken token (URL, hash, code snippet) renders without
        // any break and pushes the visible text past the text
        // container's width. `.byCharWrapping` keeps the rendered
        // line tight against the page boundary even when no word
        // boundary exists; the typical sentence still word-wraps
        // because word boundaries are checked first.
        let para = NSMutableParagraphStyle()
        para.alignment = .natural
        para.lineBreakMode = .byCharWrapping
        para.lineBreakStrategy = .standard
        out.addAttribute(.paragraphStyle, value: para,
                         range: NSRange(location: 0, length: out.length))
        return out
    }

    /// Concatenated plain-text representation for search indexing.
    static func plainText(_ blocks: [CeciliasNotesFile.Block]) -> String {
        var parts: [String] = []
        for block in blocks {
            switch block {
            case .heading(let s, _),
                 .paragraph(let s),
                 .code(let s, _),
                 .quote(let s, _),
                 .callout(let s, _):
                parts.append(s)
            case .list(_, let items):
                parts.append(items.joined(separator: "\n"))
            case .divider, .unknown:
                break
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Block rendering

    private static let bodyColor    = ParserColor(red: 0.20, green: 0.20, blue: 0.20, alpha: 1.0)
    private static let headingColor = ParserColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1.0)
    private static let muteColor    = ParserColor(red: 0.40, green: 0.40, blue: 0.40, alpha: 1.0)
    private static let codeBackground = ParserColor(white: 0.96, alpha: 1.0)
    private static let calloutBackground = ParserColor(white: 0.97, alpha: 1.0)

    private static func regularFont(size: CGFloat) -> ParserFont {
#if os(iOS)
        ParserFont.systemFont(ofSize: size, weight: .regular)
#else
        ParserFont.systemFont(ofSize: size)
#endif
    }

    private static func weightedFont(size: CGFloat, weight: ParserFont.Weight) -> ParserFont {
#if os(iOS)
        ParserFont.systemFont(ofSize: size, weight: weight)
#else
        ParserFont.systemFont(ofSize: size, weight: weight)
#endif
    }

    private static func monospacedFont(size: CGFloat) -> ParserFont {
#if os(iOS)
        ParserFont.monospacedSystemFont(ofSize: size, weight: .regular)
#else
        ParserFont.monospacedSystemFont(ofSize: size, weight: .regular)
#endif
    }

    private static func italicFont(size: CGFloat) -> ParserFont {
#if os(iOS)
        ParserFont.italicSystemFont(ofSize: size)
#else
        let base = ParserFont.systemFont(ofSize: size)
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
#endif
    }

    private static func render(_ block: CeciliasNotesFile.Block) -> NSAttributedString {
        switch block {
        case .heading(let content, let level):
            let size: CGFloat   = level == 1 ? 22 : (level == 2 ? 18 : 15)
            let weight: ParserFont.Weight = level == 1 ? .bold : .semibold
            return NSAttributedString(string: content, attributes: [
                .font: weightedFont(size: size, weight: weight),
                .foregroundColor: headingColor
            ])

        case .paragraph(let content):
            return NSAttributedString(string: content, attributes: [
                .font: regularFont(size: 15),
                .foregroundColor: bodyColor
            ])

        case .list(let style, let items):
            let lines = items.enumerated().map { (i, item) -> String in
                switch style {
                case .bullet:   return "•  \(item)"
                case .numbered: return "\(i + 1).  \(item)"
                }
            }
            return NSAttributedString(string: lines.joined(separator: "\n"), attributes: [
                .font: regularFont(size: 15),
                .foregroundColor: bodyColor
            ])

        case .code(let content, _):
            return NSAttributedString(string: content, attributes: [
                .font: monospacedFont(size: 13),
                .foregroundColor: headingColor,
                .backgroundColor: codeBackground
            ])

        case .divider:
            return NSAttributedString(string: "──────────────────────────", attributes: [
                .font: regularFont(size: 15),
                .foregroundColor: muteColor
            ])

        case .quote(let content, let attribution):
            let text = attribution.map { "\(content)\n— \($0)" } ?? content
            return NSAttributedString(string: text, attributes: [
                .font: italicFont(size: 15),
                .foregroundColor: muteColor
            ])

        case .callout(let content, let kind):
            let prefix: String = {
                switch kind {
                case .warning: return "⚠️ "
                case .tip:     return "💡 "
                case .note:    return "ℹ️ "
                }
            }()
            return NSAttributedString(string: prefix + content, attributes: [
                .font: regularFont(size: 14),
                .foregroundColor: bodyColor,
                .backgroundColor: calloutBackground
            ])

        case .unknown:
            return NSAttributedString()
        }
    }
}

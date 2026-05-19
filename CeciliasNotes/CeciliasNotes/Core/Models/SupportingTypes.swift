import CoreGraphics
import Foundation

// MARK: - PageSize

public enum PageSize: String, Codable, Sendable, CaseIterable {
    case a4
    case letter
    case ipadCanvas

    public var pointSize: CGSize {
        switch self {
        case .a4:         return CGSize(width: 794,  height: 1123)
        case .letter:     return CGSize(width: 816,  height: 1056)
        case .ipadCanvas: return CGSize(width: 1024, height: 1366)
        }
    }

    public var displayName: String {
        switch self {
        case .a4:         return "A4"
        case .letter:     return "Letter"
        case .ipadCanvas: return "iPad Canvas"
        }
    }
}

// MARK: - PageTemplate

/// Flat enum of all 18 page templates organised across 5 categories.
/// Backed by `String` raw value so SwiftData persists each template
/// as a single token (`"narrowRuled"`) instead of a JSON blob — the
/// rendering parameters (line spacing, dot size, etc.) are baked into
/// the case rather than expressed as associated values.
public enum PageTemplate: String, Codable, Sendable, Hashable, CaseIterable {

    // Lined
    case blank
    case narrowRuled
    case wideRuled
    case collegeRuled
    case twoColumn

    // Dotted
    case dotGrid5
    case dotGrid10
    case isoDots

    // Grid
    case squareGrid5
    case squareGrid10
    case engineeringGrid

    // Specialised
    case cornell
    case music
    case storyboard
    case mindMap

    // Planning
    case calendarWeek
    case dayPlanner
    case taskList
    case habitTracker

    public var category: TemplateCategory {
        switch self {
        case .blank, .narrowRuled, .wideRuled, .collegeRuled, .twoColumn:
            return .lined
        case .dotGrid5, .dotGrid10, .isoDots:
            return .dotted
        case .squareGrid5, .squareGrid10, .engineeringGrid:
            return .grid
        case .cornell, .music, .storyboard, .mindMap:
            return .specialised
        case .calendarWeek, .dayPlanner, .taskList, .habitTracker:
            return .planning
        }
    }

    public var displayName: String {
        switch self {
        case .blank:           return "blank"
        case .narrowRuled:     return "narrow ruled"
        case .wideRuled:       return "wide ruled"
        case .collegeRuled:    return "college ruled"
        case .twoColumn:       return "two column"
        case .dotGrid5:        return "dot grid 5mm"
        case .dotGrid10:       return "dot grid 10mm"
        case .isoDots:         return "iso dots"
        case .squareGrid5:     return "grid 5mm"
        case .squareGrid10:    return "grid 10mm"
        case .engineeringGrid: return "engineering"
        case .cornell:         return "cornell"
        case .music:           return "music"
        case .storyboard:      return "storyboard"
        case .mindMap:         return "mind map"
        case .calendarWeek:    return "week"
        case .dayPlanner:      return "day"
        case .taskList:        return "tasks"
        case .habitTracker:    return "habits"
        }
    }

    // MARK: String bridge (used by SwiftData stored properties)

    /// `Notebook.defaultTemplateRaw` and `Page.backgroundTemplateRaw`
    /// are stored as `String` columns. With the flat enum the bridge
    /// is just the raw value — no JSON encoding required.
    nonisolated var jsonString: String { rawValue }

    /// Decodes from a stored token. Returns `.blank` on any failure
    /// (unknown raw values, empty string).
    nonisolated static func from(jsonString: String) -> PageTemplate {
        PageTemplate(rawValue: jsonString) ?? .blank
    }
}

// MARK: - TemplateCategory

public enum TemplateCategory: String, CaseIterable, Sendable, Hashable {
    case lined
    case dotted
    case grid
    case specialised
    case planning

    public var displayName: String {
        switch self {
        case .lined:       return "lined"
        case .dotted:      return "dotted"
        case .grid:        return "grid"
        case .specialised: return "specialised"
        case .planning:    return "planning"
        }
    }
}

// MARK: - CoverTexture

public enum CoverTexture: String, Codable, Sendable, CaseIterable {
    case none
    case linen
    case grid
    case dot
    case ruled
    case craft
}

// MARK: - MediaType

public enum MediaType: String, Codable, Sendable {
    case image
    case video  // stubbed — renderer not yet implemented
}

// MARK: - TranscriptionSegment

public struct TranscriptionSegment: Codable, Sendable, Hashable {
    public var word: String
    public var startTime: Double
    public var endTime: Double
    public var confidence: Float

    public init(word: String, startTime: Double, endTime: Double, confidence: Float) {
        self.word = word
        self.startTime = startTime
        self.endTime = endTime
        self.confidence = confidence
    }
}

// MARK: - Search result types

public struct SearchResult: Sendable {
    public let notebookId: UUID
    public let pageId: UUID?
    /// 1-based page number for matches inside a page (notebook-title
    /// hits leave this nil). The library results UI surfaces this as
    /// "page 7" beneath the notebook title.
    public let pageNumber: Int?
    /// ±40-char window around the match, with `… ` ellipsis when
    /// truncated on either side. The query word itself is preserved
    /// verbatim so the UI can find and bold it.
    public let context: String
    public let type: SearchResultType

    public init(
        notebookId: UUID,
        pageId: UUID?      = nil,
        pageNumber: Int?   = nil,
        context: String,
        type: SearchResultType
    ) {
        self.notebookId = notebookId
        self.pageId     = pageId
        self.pageNumber = pageNumber
        self.context    = context
        self.type       = type
    }
}

public enum SearchResultType: Sendable {
    case notebookTitle
    case textBlock
    case transcription
    case handwriting
    /// Hit inside a long-form lecture transcript (`LectureStore`).
    /// Renders identically to `.transcription` in the UI — same
    /// "Transcripts" section, same row style, same snippet. Kept as
    /// a separate case so the source surface is unambiguous for
    /// future filters / debugging.
    case lectureTranscript
}

// MARK: - Storage info

public struct StorageInfo: Sendable {
    public let totalBytes: Int64
    public let audioBytes: Int64
    public let mediaBytes: Int64
    public let dbBytes: Int64
}

// MARK: - Subject color presets (12 curated values)

public enum CeciliasNotesColorPresets {
    public static let subjectColors: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#30B0C7", "#007AFF", "#5856D6",
        "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
    ]
}

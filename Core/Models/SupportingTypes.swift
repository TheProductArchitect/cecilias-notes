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

public enum PageTemplate: Codable, Sendable, Hashable {
    case blank
    case lined(spacing: CGFloat)
    case grid(spacing: CGFloat)
    case dotGrid(spacing: CGFloat, dotSize: CGFloat)
    case cornell
    case music

    private enum CodingKeys: String, CodingKey {
        case type, spacing, dotSize
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .blank:
            try c.encode("blank", forKey: .type)
        case .lined(let s):
            try c.encode("lined", forKey: .type)
            try c.encode(s, forKey: .spacing)
        case .grid(let s):
            try c.encode("grid", forKey: .type)
            try c.encode(s, forKey: .spacing)
        case .dotGrid(let s, let d):
            try c.encode("dotGrid", forKey: .type)
            try c.encode(s, forKey: .spacing)
            try c.encode(d, forKey: .dotSize)
        case .cornell:
            try c.encode("cornell", forKey: .type)
        case .music:
            try c.encode("music", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "lined":
            self = .lined(spacing: try c.decode(CGFloat.self, forKey: .spacing))
        case "grid":
            self = .grid(spacing: try c.decode(CGFloat.self, forKey: .spacing))
        case "dotGrid":
            self = .dotGrid(
                spacing: try c.decode(CGFloat.self, forKey: .spacing),
                dotSize: try c.decode(CGFloat.self, forKey: .dotSize)
            )
        case "cornell": self = .cornell
        case "music":   self = .music
        default:        self = .blank
        }
    }

    // Sensible defaults used in the library picker UI.
    public static let defaults: [PageTemplate] = [
        .blank,
        .lined(spacing: 32),
        .grid(spacing: 24),
        .dotGrid(spacing: 24, dotSize: 2),
        .cornell,
        .music,
    ]
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
    public let context: String
    public let type: SearchResultType
}

public enum SearchResultType: Sendable {
    case textBlock
    case transcription
    case notebookTitle
}

// MARK: - Storage info

public struct StorageInfo: Sendable {
    public let totalBytes: Int64
    public let audioBytes: Int64
    public let mediaBytes: Int64
    public let dbBytes: Int64
}

// MARK: - Subject color presets (12 curated values)

public enum InkColorPresets {
    public static let subjectColors: [String] = [
        "#FF3B30", "#FF9500", "#FFCC00", "#34C759",
        "#00C7BE", "#30B0C7", "#007AFF", "#5856D6",
        "#AF52DE", "#FF2D55", "#A2845E", "#8E8E93",
    ]
}

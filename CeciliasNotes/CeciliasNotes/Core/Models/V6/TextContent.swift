import Foundation
import SwiftData
import UIKit

/// Where this text came from. Used by analytics and AI features
/// that want to bias prompts based on provenance ("summarise the
/// user's typed notes, ignoring dictation noise") or jump back to
/// the source audio for `.dictated` text.
enum TextSource: String, Codable, CaseIterable {
    case typed
    case dictated
    case ai
    case pasted
}

/// Display size variant for a `TextContent`. Three coarse tiers —
/// the architecture explicitly defers rich text (bold / italic /
/// lists / alignment) to post-1.0. Size is the one styling axis
/// users get in V1.
enum TextSize: String, Codable, CaseIterable {
    case small
    case body
    case heading

    var pointSize: CGFloat {
        switch self {
        case .small:    return 14
        case .body:     return 17
        case .heading:  return 24
        }
    }

    var fontWeight: UIFont.Weight {
        switch self {
        case .small, .body:  return .regular
        case .heading:       return .semibold
        }
    }

    var displayName: String {
        switch self {
        case .small:    return "Small"
        case .body:     return "Body"
        case .heading:  return "Heading"
        }
    }

    var systemImage: String {
        switch self {
        case .small:    return "textformat.size.smaller"
        case .body:     return "textformat"
        case .heading:  return "textformat.size.larger"
        }
    }
}

/// Plain-text content for a `PageElement` of kind `.text`. V1 is
/// plain `String` plus a coarse `TextSize`; rich text
/// (AttributedString, lists, alignment, custom fonts) is post-1.0.
///
/// V6 (Step 3): live. `TextElementsOverlayView` renders one of
/// these per `PageElement` with `kind == .text`, with tap-to-edit
/// driven by the cursor tool. The legacy `TextBlock` entity stays
/// alongside until Step 5 migrates the dictation flow off it.
///
/// **Dictation pairing model** (architecture doc §9):
///   • When a recording starts, an `AudioContent` is created with
///     its `anchorText` relationship set to the first `TextContent`
///     span.
///   • The transcript on the original page gets a `TextContent`
///     row that owns the inverse via `audioRecordings`.
///   • If the recording overflows the page, subsequent `TextContent`
///     rows are created on new pages with `anchorAudioId` set to
///     the audio's UUID. Those continuation spans don't have the
///     audio strip visually paired above them but can still play
///     back via the UUID lookup.
@Model
final class TextContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    var text: String = ""

    var source: TextSource = TextSource.typed

    /// Display size — `.body` for new typed text and dictation,
    /// `.small` for captions, `.heading` for section headers. Added
    /// in Step 3; default ensures existing V6 rows (none today, but
    /// CloudKit-fetched rows tomorrow) decode cleanly.
    var size: TextSize = TextSize.body

    /// Continuation pointer for multi-page recordings: non-nil on
    /// secondary text spans whose audio anchor lives on the FIRST
    /// span's page. Lookup by UUID rather than relationship because
    /// the cross-page link is one-directional (audio knows its
    /// first span; continuations know their audio).
    var anchorAudioId: UUID? = nil

    /// Inverse of `AudioContent.anchorText`. SwiftData populates
    /// this when an audio recording's `anchorText` is set to this
    /// text. Empty for typed text and for continuation spans.
    @Relationship(inverse: \AudioContent.anchorText)
    var audioRecordings: [AudioContent]? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        text: String = "",
        source: TextSource = .typed,
        size: TextSize = .body,
        anchorAudioId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id            = id
        self.text          = text
        self.source        = source
        self.size          = size
        self.anchorAudioId = anchorAudioId
        self.createdAt     = createdAt
        self.updatedAt     = updatedAt
    }
}

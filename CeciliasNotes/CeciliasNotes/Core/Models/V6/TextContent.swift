import Foundation
import SwiftData

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

/// Plain-text content for a `PageElement` of kind `.text`. V1 is
/// plain `String`; rich text (AttributedString, lists, headings) is
/// post-1.0.
///
/// V6 (Step 1): inert. The legacy `TextBlock` entity still serves
/// the editor's text overlays until Step 3 migrates onto this row.
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
        anchorAudioId: UUID? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id            = id
        self.text          = text
        self.source        = source
        self.anchorAudioId = anchorAudioId
        self.createdAt     = createdAt
        self.updatedAt     = updatedAt
    }
}

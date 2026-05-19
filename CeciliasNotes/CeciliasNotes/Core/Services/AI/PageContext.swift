import Foundation
import SwiftData

/// Text-only representation of a single page, suitable for feeding
/// to a language model. Built by `PageContextBuilder` from the
/// page's `PageElement` rows; consumed by `AIService.summarizePage`
/// (and future user-invoked capabilities like Ask).
///
/// **What's included (v1):**
///   • `text` — typed `TextContent.text` from `.text` elements
///   • `dictated` — `.text` elements whose source is `.dictated`
///     (transcripts that the user keeps on the page)
///   • `stickyNotes` — `StickyNoteContent.text` from `.stickyNote`
///     elements
///   • `highlights` — `HighlightContent.capturedText` from
///     `.highlight` elements (text extracted at highlight time)
///
/// **What's omitted (v1):**
///   • Stroke handwriting — requires OCR over `PKDrawing` bytes;
///     planned as a follow-up capability with its own infrastructure.
///   • Images — requires a vision model. Not on the v1 critical path.
///   • PDF page text layers — extractable but deferred; large PDFs
///     would dominate the prompt and the on-device context window
///     would refuse anything substantial. Chunking lands with the
///     cloud-provider follow-up.
///   • Audio transcripts not yet placed on the page as `TextContent`.
///     The `AudioContent.transcript` cache exists but rendering it
///     into the page context could double-count text that's already
///     pinned as dictated `.text`. Skipped to avoid duplication.
///
/// `PageContext` is `Sendable` so it can cross actor boundaries —
/// the builder runs on the main actor (SwiftData reads), the
/// provider runs wherever the framework dispatches.
struct PageContext: Sendable {

    let pageId: UUID
    let notebookTitle: String
    let pageNumber: Int

    /// Lines collected by element kind. Each line is one text body
    /// from a single element — multi-element pages produce one line
    /// per element. The prompt builder joins these with a blank line
    /// between sections so the model sees a clear shape.
    let typedText: [String]
    let dictatedText: [String]
    let stickyNotes: [String]
    let highlights: [String]

    /// Total character count across all included content. The Service
    /// uses this to short-circuit empty pages (zero characters → no
    /// content → `AIError.empty`) and to reject pages that exceed
    /// the on-device context window (`AIError.tooLong`).
    var characterCount: Int {
        let allLines = typedText + dictatedText + stickyNotes + highlights
        return allLines.reduce(0) { $0 + $1.count }
    }

    /// `true` when the page has at least one non-empty included
    /// element body. An "empty" page (only strokes, only images, or
    /// genuinely blank) returns `false` and the call site should
    /// short-circuit before invoking the model.
    var isEmpty: Bool {
        characterCount == 0
    }

    /// Flattens the context into a single user-prompt string. The
    /// layout uses tagged section headers (`Typed notes:`, etc.) so
    /// the model can attribute parts of its summary to the right
    /// source — and so future per-source biasing prompts (e.g.
    /// "summarise typed notes, ignore dictation noise") can land
    /// without changing the encoder.
    func toPrompt() -> String {
        var lines: [String] = []
        lines.append("Notebook: \(notebookTitle), Page \(pageNumber).")
        lines.append("")

        if !typedText.isEmpty {
            lines.append("Typed notes:")
            lines.append(contentsOf: typedText)
            lines.append("")
        }

        if !dictatedText.isEmpty {
            lines.append("Dictated text:")
            lines.append(contentsOf: dictatedText)
            lines.append("")
        }

        if !stickyNotes.isEmpty {
            lines.append("Sticky notes:")
            lines.append(contentsOf: stickyNotes)
            lines.append("")
        }

        if !highlights.isEmpty {
            lines.append("Highlighted excerpts:")
            lines.append(contentsOf: highlights)
            lines.append("")
        }

        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

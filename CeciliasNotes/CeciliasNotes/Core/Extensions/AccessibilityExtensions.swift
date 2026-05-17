import Foundation
import SwiftUI
import UIKit

// MARK: - Accessibility string builders
//
// All accessibility label/hint strings in the app are computed here. No string
// literals for `.accessibilityLabel(...)` or `.accessibilityHint(...)` should
// appear in any view file — call into `A11y` instead.

enum A11y {

    // MARK: Date relative formatter (cached)

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    private static let durationFormatter: DateComponentsFormatter = {
        let f = DateComponentsFormatter()
        f.unitsStyle = .short
        f.allowedUnits = [.minute, .second]
        return f
    }()

    static func relativeDate(_ date: Date) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        durationFormatter.string(from: seconds) ?? "\(Int(seconds)) seconds"
    }

    // MARK: Notebook

    static func notebookLabel(
        title: String,
        subjectName: String?,
        pageCount: Int,
        modified: Date
    ) -> String {
        let subject = subjectName ?? "No subject"
        let pages   = pageCount == 1 ? "1 page" : "\(pageCount) pages"
        return "\(title), \(subject), \(pages), last modified \(relativeDate(modified))"
    }

    static let notebookHint = "Double tap to open"

    // MARK: Canvas

    static func canvasLabel(strokeCount: Int) -> String {
        let strokes = strokeCount == 1 ? "1 stroke" : "\(strokeCount) strokes"
        return "Drawing canvas, \(strokes)"
    }

    static let canvasHint = "Use Apple Pencil to draw. Activate the text tool to type."

    // MARK: Tool palette

    static func toolLabel(name: String, isActive: Bool) -> String {
        isActive ? "\(name), selected" : name
    }

    static let toolHint = "Double tap to select"

    // MARK: Audio annotation

    static func audioLabel(duration: Double, hasTranscription: Bool) -> String {
        let base = "Audio recording, \(self.duration(duration))"
        return hasTranscription ? "\(base), transcription available" : base
    }

    static let audioHint = "Double tap to play"

    // MARK: Media attachment

    static func mediaLabel(caption: String?) -> String {
        if let caption, !caption.isEmpty { return "Image, \(caption)" }
        return "Image"
    }

    static let mediaHint = "Double tap to select and edit"

    // MARK: Page navigation

    static func pageLabel(index: Int, total: Int) -> String {
        "Page \(index + 1) of \(total)"
    }

    // MARK: Subject row

    static func subjectLabel(name: String, notebookCount: Int) -> String {
        let nbs = notebookCount == 1 ? "1 notebook" : "\(notebookCount) notebooks"
        return "\(name), \(nbs)"
    }
}

// MARK: - High-contrast helpers

extension View {
    /// Returns 1.0 in high-contrast mode, 0.5 otherwise — for hairline borders.
    func inkBorderWidth(base: CGFloat = 0.5) -> CGFloat {
        UIAccessibility.isDarkerSystemColorsEnabled ? base * 2 : base
    }

    /// Returns `text.primary` in high-contrast mode, the supplied secondary otherwise.
    func inkSecondaryText() -> Color {
        UIAccessibility.isDarkerSystemColorsEnabled ? .inkTextPrimary : .inkTextSecondary
    }
}

// MARK: - Reduce-motion helpers

extension View {
    /// Wraps a transition so it becomes opacity-only when Reduce Motion is on.
    /// Use this everywhere instead of raw `.transition(...)` to keep a11y consistent.
    func ceciliasNotesTransition(_ transition: AnyTransition) -> some View {
        UIAccessibility.isReduceMotionEnabled
            ? self.transition(.opacity)
            : self.transition(transition)
    }
}

import Foundation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum A11y {

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short
        formatter.allowedUnits = [.minute, .second]
        return formatter.string(from: seconds) ?? "\(Int(seconds)) seconds"
    }

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

    static func canvasLabel(strokeCount: Int) -> String {
        let strokes = strokeCount == 1 ? "1 stroke" : "\(strokeCount) strokes"
        return "Drawing canvas, \(strokes)"
    }

    static let canvasHint = "Use Apple Pencil to draw. Activate the text tool to type."

    static func toolLabel(name: String, isActive: Bool) -> String {
        isActive ? "\(name), selected" : name
    }

    static let toolHint = "Double tap to select"

    static func audioLabel(duration: Double, hasTranscription: Bool) -> String {
        let base = "Audio recording, \(self.duration(duration))"
        return hasTranscription ? "\(base), transcription available" : base
    }

    static let audioHint = "Double tap to play"

    static func mediaLabel(caption: String?) -> String {
        if let caption, !caption.isEmpty { return "Image, \(caption)" }
        return "Image"
    }

    static let mediaHint = "Double tap to select and edit"

    static func pageLabel(index: Int, total: Int) -> String {
        "Page \(index + 1) of \(total)"
    }

    static func subjectLabel(name: String, notebookCount: Int) -> String {
        let nbs = notebookCount == 1 ? "1 notebook" : "\(notebookCount) notebooks"
        return "\(name), \(nbs)"
    }
}

extension View {
    func inkBorderWidth(base: CGFloat = 0.5) -> CGFloat {
#if canImport(UIKit)
        UIAccessibility.isDarkerSystemColorsEnabled ? base * 2 : base
#else
        base
#endif
    }

    func ceciliasNotesTransition(_ transition: AnyTransition) -> some View {
#if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
            ? self.transition(.opacity)
            : self.transition(transition)
#elseif canImport(AppKit)
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? self.transition(.opacity)
            : self.transition(transition)
#else
        self.transition(transition)
#endif
    }
}

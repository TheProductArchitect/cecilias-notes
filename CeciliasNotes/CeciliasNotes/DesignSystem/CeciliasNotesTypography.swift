import SwiftUI
import UIKit

// MARK: - SwiftUI Font tokens

public extension Font {
    static let ceciliasNotesDisplay:    Font = .system(size: 34, weight: .light,    design: .default)
    static let ceciliasNotesTitle1:     Font = .system(size: 28, weight: .regular,  design: .default)
    static let ceciliasNotesLargeIcon:  Font = .system(size: 22, weight: .light,    design: .default)
    static let ceciliasNotesTitle2:     Font = .system(size: 22, weight: .regular,  design: .default)
    static let ceciliasNotesSectionHero: Font = .system(size: 20, weight: .semibold, design: .default)
    static let ceciliasNotesSectionIcon: Font = .system(size: 20, weight: .light,   design: .default)
    static let ceciliasNotesLargeMetric: Font = .system(size: 28, weight: .light,   design: .default)
    static let ceciliasNotesMidIcon:    Font = .system(size: 18, weight: .light,    design: .default)
    static let ceciliasNotesHeadline:   Font = .system(size: 17, weight: .semibold, design: .default)
    static let ceciliasNotesBody:       Font = .system(size: 17, weight: .regular,  design: .default)
    static let ceciliasNotesCallout:    Font = .system(size: 16, weight: .regular,  design: .default)
    static let ceciliasNotesSubhead:    Font = .system(size: 15, weight: .regular,  design: .default)
    static let ceciliasNotesRowLabel:   Font = .system(size: 14, weight: .medium,   design: .default)
    static let ceciliasNotesRowSelected: Font = .system(size: 14, weight: .semibold, design: .default)
    static let ceciliasNotesFootnote:   Font = .system(size: 13, weight: .regular,  design: .default)
    static let ceciliasNotesCaption:    Font = .system(size: 12, weight: .regular,  design: .default)
    static let ceciliasNotesTag:        Font = .system(size: 12, weight: .medium,   design: .default)
    static let ceciliasNotesMono:       Font = .system(size: 13, weight: .regular,  design: .monospaced)
}

// MARK: - UIFont tokens (for UIKit / PencilKit contexts)

public extension UIFont {
    static let ceciliasNotesDisplay:   UIFont = .systemFont(ofSize: 34, weight: .light)
    static let ceciliasNotesTitle1:    UIFont = .systemFont(ofSize: 28, weight: .regular)
    static let ceciliasNotesTitle2:    UIFont = .systemFont(ofSize: 22, weight: .regular)
    static let ceciliasNotesHeadline:  UIFont = .systemFont(ofSize: 17, weight: .semibold)
    static let ceciliasNotesBody:      UIFont = .systemFont(ofSize: 17, weight: .regular)
    static let ceciliasNotesCallout:   UIFont = .systemFont(ofSize: 16, weight: .regular)
    static let ceciliasNotesSubhead:   UIFont = .systemFont(ofSize: 15, weight: .regular)
    static let ceciliasNotesFootnote:  UIFont = .systemFont(ofSize: 13, weight: .regular)
    static let ceciliasNotesCaption:   UIFont = .systemFont(ofSize: 12, weight: .regular)
    static let ceciliasNotesMono:      UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
}

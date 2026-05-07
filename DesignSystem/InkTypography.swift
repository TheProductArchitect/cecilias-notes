import SwiftUI
import UIKit

// MARK: - SwiftUI Font tokens

public extension Font {
    static let inkDisplay:   Font = .system(size: 34, weight: .light,       design: .default)
    static let inkTitle1:    Font = .system(size: 28, weight: .regular,     design: .default)
    static let inkTitle2:    Font = .system(size: 22, weight: .regular,     design: .default)
    static let inkHeadline:  Font = .system(size: 17, weight: .semibold,    design: .default)
    static let inkBody:      Font = .system(size: 17, weight: .regular,     design: .default)
    static let inkCallout:   Font = .system(size: 16, weight: .regular,     design: .default)
    static let inkSubhead:   Font = .system(size: 15, weight: .regular,     design: .default)
    static let inkFootnote:  Font = .system(size: 13, weight: .regular,     design: .default)
    static let inkCaption:   Font = .system(size: 12, weight: .regular,     design: .default)
    static let inkMono:      Font = .system(size: 13, weight: .regular,     design: .monospaced)
}

// MARK: - UIFont tokens (for UIKit / PencilKit contexts)

public extension UIFont {
    static let inkDisplay:   UIFont = .systemFont(ofSize: 34, weight: .light)
    static let inkTitle1:    UIFont = .systemFont(ofSize: 28, weight: .regular)
    static let inkTitle2:    UIFont = .systemFont(ofSize: 22, weight: .regular)
    static let inkHeadline:  UIFont = .systemFont(ofSize: 17, weight: .semibold)
    static let inkBody:      UIFont = .systemFont(ofSize: 17, weight: .regular)
    static let inkCallout:   UIFont = .systemFont(ofSize: 16, weight: .regular)
    static let inkSubhead:   UIFont = .systemFont(ofSize: 15, weight: .regular)
    static let inkFootnote:  UIFont = .systemFont(ofSize: 13, weight: .regular)
    static let inkCaption:   UIFont = .systemFont(ofSize: 12, weight: .regular)
    static let inkMono:      UIFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
}

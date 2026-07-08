import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Single source of truth for how NOTE TEXT reads on a page — the
/// editorial voice of the product applied to the user's own words.
///
/// Every writer of page text consumes these tokens: the iPad/iPhone
/// rich-text stack (`RichTextController.defaultAttributes`), the Mac
/// editor (`MacRichTextCodec.defaultTypingAttributes`), both
/// dictation pipelines, and the meeting-summary block. A page must
/// carry the same voice no matter which device wrote it — that's
/// the whole point of one spec instead of three hardcoded font
/// literals.
///
/// The voice, in numbers:
///   • one shared body size on the page (a page is a fixed point
///     space; per-platform sizes made the same note render at
///     different physical sizes across devices)
///   • an airy line height and real paragraph space — dense default
///     UIKit/AppKit leading is what made note text read "old
///     school" against the rest of the chrome
///   • a whisper of positive tracking on body text (modern,
///     minimal), tight negative tracking on headings (editorial)
///   • the tracked-uppercase eyebrow (SUMMARY, etc.) reuses the
///     same kern the brand language uses everywhere else
enum NoteTypography {

    // MARK: Point sizes (page-space, shared across platforms)

    static let bodyPointSize: CGFloat = 16
    static let smallPointSize: CGFloat = 13
    static let headingPointSize: CGFloat = 21
    static let eyebrowPointSize: CGFloat = 10

    // MARK: Rhythm

    /// Breathing room between wrapped lines — the single biggest
    /// lever in making body text feel considered instead of dense.
    /// Expressed as extra points per line (ratio of the font size),
    /// NOT `lineHeightMultiple`: the multiple makes NSTextView draw
    /// an oversized, oddly-anchored caret that jumps on empty lines.
    /// `lineSpacing` gives the same rhythm with a normal caret.
    static let lineSpacingRatio: CGFloat = 0.30
    /// Space after a hard return. Soft-wrapped lines stay tight.
    static let paragraphSpacing: CGFloat = 10
    /// Extra space above a heading paragraph.
    static let headingSpacingBefore: CGFloat = 14

    // MARK: Tracking

    static let bodyKern: CGFloat = 0.2
    static let smallKern: CGFloat = 0.25
    static let headingKern: CGFloat = -0.3
    /// Tracked-uppercase label (eyebrow) — matches the brand chrome.
    static let eyebrowKern: CGFloat = 1.6

    // MARK: Paragraph style

    static func paragraphStyle(
        alignment: NSTextAlignment = .left,
        isHeading: Bool = false,
        pointSize: CGFloat = bodyPointSize
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineSpacing = (pointSize * lineSpacingRatio).rounded()
        style.paragraphSpacing = paragraphSpacing
        if isHeading {
            style.paragraphSpacingBefore = headingSpacingBefore
        }
        return style
    }

    // MARK: Platform fonts

    #if canImport(UIKit)
    static var bodyFont: UIFont { .systemFont(ofSize: bodyPointSize, weight: .regular) }
    static var smallFont: UIFont { .systemFont(ofSize: smallPointSize, weight: .regular) }
    static var headingFont: UIFont { .systemFont(ofSize: headingPointSize, weight: .semibold) }
    static var eyebrowFont: UIFont { .systemFont(ofSize: eyebrowPointSize, weight: .semibold) }
    #else
    static var bodyFont: NSFont { .systemFont(ofSize: bodyPointSize, weight: .regular) }
    static var smallFont: NSFont { .systemFont(ofSize: smallPointSize, weight: .regular) }
    static var headingFont: NSFont { .systemFont(ofSize: headingPointSize, weight: .semibold) }
    static var eyebrowFont: NSFont { .systemFont(ofSize: eyebrowPointSize, weight: .semibold) }
    #endif

    /// Kern that matches a given role's font size — callers that
    /// build fonts dynamically (heading levels, size multipliers)
    /// still track consistently.
    static func kern(forPointSize pointSize: CGFloat) -> CGFloat {
        if pointSize >= headingPointSize { return headingKern }
        if pointSize <= smallPointSize { return smallKern }
        return bodyKern
    }
}

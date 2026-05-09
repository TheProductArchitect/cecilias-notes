import CoreGraphics
import Foundation

/// Sidecar storage for `Page.extraHeight` (the auto-grow extension on the
/// last page of a notebook). Stored in `UserDefaults` keyed by the page's
/// UUID so we don't have to bump the SwiftData schema version — bumping
/// past V3 with the same model types as V3 crashes SwiftData with
/// "Duplicate version checksums detected", so we keep the data layer
/// untouched and persist this small numeric value externally.
///
/// The data is genuinely sidecar — losing it on uninstall is fine. The
/// page's strokes are the durable thing (those live in SwiftData). On a
/// fresh launch with no recorded extension, the page renders at its
/// base size; any strokes drawn into the previously-extended area
/// remain in `PKDrawing` and the page auto-grows again the next time
/// the auto-extend trigger fires near them.
enum PageExtraHeightStore {

    private static let prefix = "ink.page.extraHeight."

    /// Total accumulated extension for a page, in points. nil if the
    /// page has never been extended.
    static func extraHeight(forPageId pageId: UUID) -> CGFloat {
        let raw = UserDefaults.standard.double(forKey: prefix + pageId.uuidString)
        return CGFloat(raw)
    }

    /// Add `additional` points of extension to the page's current
    /// stored height. Returns the new total.
    @discardableResult
    static func extend(pageId: UUID, byAdditional additional: CGFloat) -> CGFloat {
        let key = prefix + pageId.uuidString
        let current = UserDefaults.standard.double(forKey: key)
        let next    = current + Double(additional)
        UserDefaults.standard.set(next, forKey: key)
        return CGFloat(next)
    }

    /// Drop the stored extension for a page (used when a page is
    /// deleted, so we don't leak entries in UserDefaults).
    static func clear(pageId: UUID) {
        UserDefaults.standard.removeObject(forKey: prefix + pageId.uuidString)
    }
}

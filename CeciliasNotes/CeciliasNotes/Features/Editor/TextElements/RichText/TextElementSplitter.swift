import Foundation
import SwiftData
import SwiftUI
import UIKit

/// Auto-split a text block whose content overflows the page. The
/// editor's height clamp already prevents glyphs from rendering past
/// the page boundary while typing, but on commit (when the user
/// dismisses the keyboard) any content that doesn't fit is moved
/// onto a fresh text block on the next page — creating one if the
/// current page is the last in the notebook.
///
/// Why split at end-of-editing rather than per-keystroke: mutating
/// the live `attributedText` of an active first responder cancels
/// the user's in-flight typing/dictation and frequently causes
/// caret-position drift. Splitting only once the user has stepped
/// away avoids both classes of bug while still enforcing the
/// "nothing past the page" contract — the user types freely, the
/// height clamp keeps the overflow off the chrome below, and the
/// commit relocates it cleanly.
enum TextElementSplitter {

    /// Vertical padding the editor leaves below the last line — must
    /// match `TextElementView.height`'s `+ 6` so the splitter
    /// agrees with what the user can visually see fits.
    private static let bottomPadding: CGFloat = 6

    /// Width / placement constants for the continuation element on
    /// the new page — mirrors `DictationFlowCommit`'s constants so
    /// dictation and typed-overflow blocks lay out identically.
    private static let textElementWidth: Double  = 0.8
    private static let textElementTopInset: Double = 0.08
    private static let textElementInitialHeight: Double = 0.5

    /// Run the split check. Returns true if a split happened (the
    /// caller should refresh fetched elements / pages).
    @discardableResult
    static func splitIfNeeded(
        element: PageElement,
        content: TextContent,
        pageInkColor: UIColor,
        pageSize: CGSize,
        originY: CGFloat
    ) -> Bool {
        // Reconstitute the attributed string from storage. The split
        // operates on the *persisted* representation so dictation /
        // AI-written blocks (which only update `text`) split cleanly.
        let attributed = current(content, ink: pageInkColor)
        guard attributed.length > 0 else { return false }

        let pageMargin: CGFloat = 32
        let contentWidth = max(40, pageSize.width - 2 * pageMargin)
        let availableHeight = max(40, pageSize.height - originY - bottomPadding)

        let measured = ceil(attributed.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        ).height)

        guard measured > availableHeight else { return false }

        let splitIndex = findSplitIndex(
            attributed: attributed,
            width: contentWidth,
            available: availableHeight
        )
        guard splitIndex > 0, splitIndex < attributed.length else { return false }

        // Snap to the nearest preceding paragraph or whitespace
        // boundary so we don't slice a word in half.
        let snapped = snapToBoundary(attributed.string, near: splitIndex)
        guard snapped > 0, snapped < attributed.length else { return false }

        let fit = attributed.attributedSubstring(from: NSRange(location: 0, length: snapped))
        // Drop the leading newline / whitespace from the overflow so
        // the continuation block doesn't start with a blank line.
        var overflowStart = snapped
        let chars = Array(attributed.string)
        while overflowStart < chars.count, (chars[overflowStart] == "\n" || chars[overflowStart] == " ") {
            overflowStart += 1
        }
        guard overflowStart < attributed.length else { return false }
        let overflow = attributed.attributedSubstring(
            from: NSRange(location: overflowStart, length: attributed.length - overflowStart)
        )

        // Persist the fit-portion back into the current row.
        commit(attributed: fit, into: content)
        // Splitting is a user-edit on this page — invalidate the
        // inkbook stash so the mirror reflects the post-split text.
        Page.clearInkbookStash(
            forPageId: element.pageId,
            context: StorageService.shared.context
        )

        // Place overflow on the next page (creating one if needed).
        placeOverflow(
            overflow: overflow,
            afterPageId: element.pageId,
            notebookId: element.notebookId
        )
        return true
    }

    // MARK: - Persistence helpers

    private static func current(_ content: TextContent, ink: UIColor) -> NSAttributedString {
        if let data = content.attributedTextData, !data.isEmpty,
           let decoded = try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: data
           ) {
            return decoded
        }
        let attrs = RichTextController.defaultAttributes(ink: ink)
        return NSAttributedString(string: content.text, attributes: attrs)
    }

    private static func commit(attributed value: NSAttributedString, into content: TextContent) {
        let plain = value.string
        if content.text != plain { content.text = plain }
        if let data = try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        ), content.attributedTextData != data {
            content.attributedTextData = data
        }
        content.updatedAt = Date()
    }

    private static func placeOverflow(
        overflow: NSAttributedString,
        afterPageId: UUID,
        notebookId: UUID
    ) {
        let storage = StorageService.shared
        let context = storage.context

        let notebookDescriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId }
        )
        guard let notebook = try? context.fetch(notebookDescriptor).first,
              let parentPage = storage.fetchPage(id: afterPageId) else {
            return
        }

        // Prefer the existing next page; create one only when this
        // is the last page in the notebook. This means typing past
        // the end of page N flows into page N+1 if it already
        // exists, joining at the top.
        let allPages = storage.fetchPages(in: notebook).sorted { $0.pageNumber < $1.pageNumber }
        let nextPage: Page
        if let existing = allPages.first(where: { $0.pageNumber == parentPage.pageNumber + 1 }) {
            nextPage = existing
        } else if let made = try? storage.createPage(
            in: notebook,
            after: parentPage.pageNumber,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        ) {
            nextPage = made
        } else {
            return
        }

        // Find an open Y on the next page: scan existing non-deleted
        // elements, take the largest `y + height` (clamped to [0,1]),
        // and place the overflow just below. Falls back to the
        // default top inset when the next page is empty. Avoids
        // stomping on existing typed / dictated content.
        let pid = nextPage.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> {
                $0.pageId == pid && $0.deletedAt == nil
            }
        )
        let existingOnNext = (try? context.fetch(descriptor)) ?? []
        let openY: Double
        if existingOnNext.isEmpty {
            openY = textElementTopInset
        } else {
            let lowestBottom = existingOnNext
                .map { $0.normalizedY + $0.normalizedHeight }
                .max() ?? textElementTopInset
            // Small gap below the existing content; clamp so we
            // don't push the new element past the page bottom.
            openY = min(0.95, max(textElementTopInset, lowestBottom + 0.01))
        }

        let element = PageElement(
            id: UUID(),
            pageId: nextPage.id,
            notebookId: notebookId,
            kind: .text,
            normalizedX: (1 - textElementWidth) / 2,
            normalizedY: openY,
            normalizedWidth: textElementWidth,
            normalizedHeight: textElementInitialHeight,
            zIndex: (existingOnNext.map(\.zIndex).max() ?? 0) + 1
        )
        let content = TextContent(
            text: overflow.string,
            source: .typed,
            size: .body,
            attributedTextData: try? NSKeyedArchiver.archivedData(
                withRootObject: overflow,
                requiringSecureCoding: true
            )
        )
        element.textContent = content
        context.insert(element)
        do {
            try context.save()
        } catch {
            // Failure here means a long text block split off an
            // overflow tail but the new tail-element wasn't
            // persisted — the user types past the bottom of the
            // page and the overflowing text never reappears on
            // the continuation. Log so the lossy split is visible
            // in device logs.
            #if DEBUG
            dlog("[TextSplit] new tail element SAVE FAILED: \(error)")
            #endif
        }

        // Let overlays re-fetch so the new element appears
        // immediately rather than waiting on the next view-tree
        // invalidation.
        NotificationCenter.default.post(name: .textElementsChanged, object: nil)
    }

    // MARK: - Split index search

    /// Largest character count `n` such that `attributed[0..<n]`
    /// wraps to a height that fits within `available`. Binary search
    /// keeps this cheap even for long blocks.
    private static func findSplitIndex(
        attributed: NSAttributedString,
        width: CGFloat,
        available: CGFloat
    ) -> Int {
        var lo = 1
        var hi = attributed.length
        var best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            let prefix = attributed.attributedSubstring(from: NSRange(location: 0, length: mid))
            let h = ceil(prefix.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
            if h <= available {
                best = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return best
    }

    /// Snap a character index backward to the nearest paragraph
    /// boundary (newline) or, failing that, the nearest whitespace.
    /// Avoids splitting a word in half.
    private static func snapToBoundary(_ s: String, near index: Int) -> Int {
        let chars = Array(s)
        let safeIdx = min(max(0, index), chars.count)
        // Prefer a newline within the window of the last ~120 chars
        // before `index`. Falling back to any whitespace, then to
        // the raw index if neither is found.
        let windowStart = max(0, safeIdx - 120)
        if let nl = (windowStart..<safeIdx).reversed().first(where: { chars[$0] == "\n" }) {
            return nl + 1   // split after the newline
        }
        if let ws = (windowStart..<safeIdx).reversed().first(where: { chars[$0].isWhitespace }) {
            return ws + 1
        }
        return safeIdx
    }
}

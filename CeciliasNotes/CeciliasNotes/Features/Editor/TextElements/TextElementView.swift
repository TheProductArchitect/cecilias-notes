import SwiftData
import SwiftUI
import UIKit

/// Renders one V6 `PageElement` of kind `.text` inside its
/// normalised page bounds. Composes `TextEditorRepresentable` for
/// the actual text-editing surface, plus selection chrome (dashed
/// border) and a per-element `RichTextController` that drives the
/// floating formatting toolbar.
///
/// **Layout rules (post-Pass 1):**
///   • Text blocks are full-content-width and anchored to the page's
///     left margin (`pageMargin`). The element's stored
///     `normalizedX` / `normalizedWidth` are ignored at the view
///     layer — text blocks aren't horizontally resizable.
///   • Vertical position uses the element's stored `normalizedY`,
///     clamped so the block can't extend past the page bottom.
///
/// **Rich text (post-Pass 2):**
///   • The text view reads from / writes to `content.attributedTextData`
///     (NSKeyedArchiver of `NSAttributedString`). The plain `text`
///     field is kept in sync as the string projection so search,
///     AI prompts, and export work unchanged for typed + dictated
///     rows alike.
///   • A floating toolbar (`RichTextToolbar`) appears above the
///     keyboard when this element is focused, with curated bold /
///     italic / underline / strikethrough, headings, sizes,
///     alignment, font family, list, and color controls.
struct TextElementView: View {

    @Bindable var element: PageElement
    @Bindable var content: TextContent
    let pageSize: CGSize
    @Binding var isSelected: Bool
    @Binding var isEditing: Bool

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var controller = RichTextController()
    @State private var attributed: NSAttributedString = NSAttributedString()
    /// Tracks whether we've seeded `attributed` from `content` yet —
    /// the seed runs once per view instance so SwiftData refreshes
    /// don't blow away typed text mid-edit. External mutations (e.g.
    /// dictation appending to `content.text`) are picked up via the
    /// `onChange(of: content.text)` handler.
    @State private var didSeed: Bool = false
    /// Transient vertical drag delta — applied live to the displayed
    /// position and committed to `element.normalizedY` on `.onEnded`.
    /// Text blocks span the full content width so only the Y axis moves.
    @State private var dragOffsetY: CGFloat = 0

    private var pageInkColor: UIColor {
        colorScheme == .dark
            ? UIColor(hex: "#EDEDEB")
            : UIColor(hex: "#1C1C1A")
    }

    /// Horizontal inset from the page edge — text blocks anchor here
    /// regardless of the element's stored `normalizedX`. The hard
    /// rule "nothing extends past the page" is enforced for text by
    /// making the block span the full content width (no horizontal
    /// resize) and pinning the left edge to this margin.
    private static let pageMargin: CGFloat = 32

    private var width: CGFloat {
        max(40, pageSize.width - 2 * Self.pageMargin)
    }
    /// Visual height — measured from the attributed string so the box
    /// hugs the actual last line of content (no extra empty space at
    /// the bottom). Clamped at the page boundary so a long block
    /// can't extend past the page; Pass 3 will split overflow onto a
    /// new page.
    private var height: CGFloat {
        let cw = width
        let measured: CGFloat
        if attributed.length == 0 {
            // Empty editor: a single line's worth of room so the
            // caret has something to land on.
            let ink = pageInkColor
            let probe = NSAttributedString(
                string: " ",
                attributes: RichTextController.defaultAttributes(ink: ink)
            )
            measured = ceil(probe.boundingRect(
                with: CGSize(width: cw, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
        } else {
            measured = ceil(attributed.boundingRect(
                with: CGSize(width: cw, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height)
        }
        // Small bottom padding so the caret doesn't sit flush
        // against the edge of the selection chrome.
        let padded = measured + 6
        let maxH = pageSize.height - originY
        return max(24, min(padded, maxH))
    }
    private var originY: CGFloat {
        let raw = element.normalizedY * pageSize.height + dragOffsetY
        return max(0, min(pageSize.height - 20, raw))
    }
    private var origin: CGPoint {
        CGPoint(x: Self.pageMargin, y: originY)
    }

    /// Drag gesture active when the block is selected but not being edited.
    /// Text blocks only move vertically (full-width layout, no horizontal resize).
    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                dragOffsetY = value.translation.height
            }
            .onEnded { value in
                let rawY = element.normalizedY * pageSize.height + value.translation.height
                let clampedY = max(0, min(pageSize.height - 20, rawY))
                element.normalizedY = clampedY / pageSize.height
                element.updatedAt   = Date()
                dragOffsetY = 0
            }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditorRepresentable(
                attributed: $attributed,
                size: content.size,
                isEditing: $isEditing,
                textColor: pageInkColor,
                controller: controller
            )
            .overlay(
                Group {
                    if isSelected && !isEditing {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(
                                theme.accent,
                                style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                            )
                            .padding(-2)
                    }
                }
            )
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(isSelected && !isEditing ? moveGesture : nil)
        .position(x: origin.x + width / 2, y: origin.y + height / 2)
        .rotationEffect(.radians(element.rotation))
        .onAppear { seedIfNeeded() }
        .onChange(of: attributed) { _, newValue in
            persist(newValue)
        }
        .onChange(of: content.text) { _, _ in
            // External mutation (dictation appending text, an AI
            // path updating the row, etc.). Re-seed only while
            // *not* editing — blowing away the buffer mid-typing
            // would cancel the keyboard / dictation session.
            reseedIfExternallyChanged()
        }
        .onChange(of: isEditing) { _, nowEditing in
            if !nowEditing {
                // Sync the stored normalizedHeight with the
                // measured layout so other consumers (lasso, AI
                // context, tap-catcher hit testing) see the same
                // rect the user sees.
                syncStoredHeight()
                // Run the auto-split when the user commits.
                // Splitting while first responder would cancel
                // in-flight typing/dictation.
                let didSplit = TextElementSplitter.splitIfNeeded(
                    element: element,
                    content: content,
                    pageInkColor: pageInkColor,
                    pageSize: pageSize,
                    originY: originY
                )
                if didSplit {
                    attributed = decodeAttributed(from: content)
                        ?? makeAttributed(from: content.text)
                    syncStoredHeight()
                }
            }
        }
        .onChange(of: content.size) { _, _ in
            content.updatedAt = Date()
            element.updatedAt = Date()
        }
    }

    // MARK: - Seed / persist

    private func seedIfNeeded() {
        guard !didSeed else { return }
        // Prefer the rich-text payload when it's consistent with
        // the plain-text projection. If something has mutated
        // `content.text` since the attributed payload was last
        // written (dictation is the canonical case — it touches
        // only `text`), fall back to a plain seed so the visible
        // text actually matches the stored row.
        if let decoded = decodeAttributed(from: content),
           decoded.string == content.text {
            attributed = decoded
        } else {
            attributed = makeAttributed(from: content.text)
        }
        didSeed = true
    }

    /// Re-seed `attributed` if `content.text` has diverged from what
    /// the editor currently shows. Called when the underlying row is
    /// mutated by a non-editor path (dictation, AI rewrite, sync).
    /// No-op while editing — we don't blow away an in-flight typing
    /// or dictation session.
    private func reseedIfExternallyChanged() {
        guard didSeed, !isEditing else { return }
        if attributed.string == content.text { return }
        if let decoded = decodeAttributed(from: content),
           decoded.string == content.text {
            attributed = decoded
        } else {
            attributed = makeAttributed(from: content.text)
        }
    }

    /// Push the measured visual height back into the element's
    /// stored normalised height so downstream consumers (lasso /
    /// AI context / tap hit-testing) see the same rect the user
    /// sees. Idempotent — only writes on actual divergence.
    private func syncStoredHeight() {
        let measured = height
        let normalized = Double(measured / pageSize.height)
        let delta = abs(element.normalizedHeight - normalized)
        guard delta > 0.001 else { return }
        element.normalizedHeight = normalized
        // Pin x/width to the visible layout so persisted rect and
        // rendered rect agree. The visible x is `pageMargin`; the
        // visible width is the full content width.
        let normMargin = Double(Self.pageMargin / pageSize.width)
        let normWidth  = Double(width / pageSize.width)
        if abs(element.normalizedX - normMargin) > 0.001 {
            element.normalizedX = normMargin
        }
        if abs(element.normalizedWidth - normWidth) > 0.001 {
            element.normalizedWidth = normWidth
        }
        element.updatedAt = Date()
    }

    private func persist(_ value: NSAttributedString) {
        // Keep plain text in sync — search, AI prompts, export, and
        // the dictation pipeline all read `content.text` directly.
        let plain = value.string
        let textChanged = content.text != plain
        if textChanged {
            content.text = plain
        }
        if let data = encodeAttributed(value) {
            // Only write when the encoded payload actually changed so
            // CloudKit doesn't see spurious updates.
            if content.attributedTextData != data {
                content.attributedTextData = data
            }
        }
        content.updatedAt = Date()
        element.updatedAt = Date()

        // Invalidate the inkbook block stash so the next mirror
        // export reflects the iPad edit. Without this, an MCP-
        // sourced page would forever round-trip its original AI
        // text into the mirror even after the user retypes the
        // page. No-op when the page wasn't inkbook-sourced.
        if textChanged {
            Page.clearInkbookStash(
                forPageId: element.pageId,
                context: StorageService.shared.context
            )
        }
    }

    private func makeAttributed(from plain: String) -> NSAttributedString {
        let attrs = RichTextController.defaultAttributes(ink: pageInkColor)
        return NSAttributedString(string: plain, attributes: attrs)
    }

    private func decodeAttributed(from content: TextContent) -> NSAttributedString? {
        guard let data = content.attributedTextData, !data.isEmpty else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: NSAttributedString.self,
            from: data
        )
    }

    private func encodeAttributed(_ value: NSAttributedString) -> Data? {
        try? NSKeyedArchiver.archivedData(
            withRootObject: value,
            requiringSecureCoding: true
        )
    }
}

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

    /// Live lasso drag: when this text element is part of the active
    /// lasso selection and the user is dragging the chrome, follow
    /// the chrome's vertical translation in real time so the block
    /// and its bounding box move together. Text blocks are full-
    /// content-width and can't translate horizontally, so only the
    /// height component is consumed.
    @ObservedObject private var lassoSelection = LassoSelectionState.shared
    @ObservedObject private var lassoLiveDrag  = LassoLiveDrag.shared
    private var lassoDragOffsetY: CGFloat {
        guard lassoLiveDrag.isManipulating,
              lassoSelection.selectedElementIds.contains(element.id)
        else { return 0 }
        return lassoLiveDrag.transientOffset.height
    }

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
    /// Cached content measurement (padded, unclamped). Text layout
    /// via `boundingRect` is the expensive part of this view's body
    /// — recomputing it on EVERY body evaluation made drags visibly
    /// stutter, because each drag frame changes `dragOffsetY` and
    /// re-runs body. The measurement only actually changes when the
    /// attributed text changes, so it's cached here and refreshed
    /// from `onChange(of: attributed)`; the per-frame `height` read
    /// is then a cheap clamp.
    @State private var measuredContentHeight: CGFloat = 24
    /// Keystroke-persist debounce state — see `schedulePersist`.
    @State private var persistTask: Task<Void, Never>?
    @State private var hasPendingPersist = false
    @State private var lastMeasureAt: Date = .distantPast
    /// External-change reseed coalescer (dictation partials).
    @State private var reseedTask: Task<Void, Never>?

    private func remeasureContentHeight() {
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
        // Trim the bottom buffer to a single point — earlier we
        // padded by 6pt to keep the caret off the chrome edge, but
        // it left a visible band of empty space below the last
        // line so the selection box always read as "much bigger
        // than the text." 2pt is enough for the caret without
        // creating that perception.
        measuredContentHeight = measured + 2
    }

    /// Visual height — cached measurement clamped at the page
    /// boundary so a long block can't extend past the page; Pass 3
    /// will split overflow onto a new page.
    private var height: CGFloat {
        let maxH = pageSize.height - originY
        return max(24, min(measuredContentHeight, maxH))
    }
    private var originY: CGFloat {
        let raw = element.normalizedY * pageSize.height + dragOffsetY + lassoDragOffsetY
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
                LassoTransformUndo.withUndo(
                    elementId: element.id, actionName: "Move Text"
                ) {
                    element.normalizedY = clampedY / pageSize.height
                    element.updatedAt   = Date()
                }
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
                            // Chrome hugs the editor's content frame.
                            // The earlier -2pt outset made the box
                            // read as "padded around the text" even
                            // for short single-line blocks.
                    }
                }
            )
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        // Tap while selected (not editing) enters edit mode. The
        // overlay's tap catcher unmounts once the element is
        // selected — it competed with the move gesture — so the
        // second-tap-to-edit affordance lives here now.
        .onTapGesture {
            if isSelected && !isEditing { isEditing = true }
        }
        .gesture(isSelected && !isEditing ? moveGesture : nil)
        .position(x: origin.x + width / 2, y: origin.y + height / 2)
        .rotationEffect(.radians(element.rotation))
        .lassoRotationPreview(elementId: element.id)
        .onAppear {
            seedIfNeeded()
            remeasureContentHeight()
        }
        .onChange(of: attributed) { _, newValue in
            // Fires on EVERY keystroke. Re-measuring the full layout
            // and NSKeyedArchiver-encoding the whole attributed
            // string here froze the main thread on long blocks (an
            // hour-long meeting transcript is 50–100 KB — hundreds
            // of ms PER KEYSTROKE). Measure on a short throttle so
            // the box still grows while typing; persist on a
            // trailing debounce with the archive off-main.
            if Date().timeIntervalSince(lastMeasureAt) > 0.25 {
                lastMeasureAt = Date()
                remeasureContentHeight()
            }
            schedulePersist(newValue)
        }
        .onDisappear {
            flushPendingPersist()
        }
        .onChange(of: content.text) { _, _ in
            // External mutation (dictation appending text, an AI
            // path updating the row, etc.). Re-seed only while
            // *not* editing — blowing away the buffer mid-typing
            // would cancel the keyboard / dictation session.
            //
            // Coalesced: dictation delivers partials 2–5×/s and each
            // reseed rebuilds the attributed string + relayouts the
            // whole UITextView. On a long transcript that alone
            // saturated the main thread for the length of the
            // recording. A 250 ms trailing debounce caps relayout at
            // 4/s and always lands the final text.
            reseedTask?.cancel()
            reseedTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                reseedIfExternallyChanged()
            }
        }
        .onChange(of: isEditing) { _, nowEditing in
            if !nowEditing {
                // Commit any debounced keystrokes FIRST — the
                // splitter below reads `content.text` /
                // `attributedTextData` and must see the final text.
                flushPendingPersist()
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

    /// Trailing-debounced persist: waits for a 350 ms pause in
    /// typing, archives the attributed string on a background
    /// thread (the immutable copy is safe to encode off-main), and
    /// applies the row writes back on the main actor.
    private func schedulePersist(_ value: NSAttributedString) {
        hasPendingPersist = true
        persistTask?.cancel()
        persistTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            lastMeasureAt = Date()
            remeasureContentHeight()
            // `copy()` snapshots the attributed string into an
            // immutable instance; boxed because region analysis
            // can't prove NSAttributedString.copy is disconnected
            // from the main-actor region (for already-immutable
            // instances it returns self). Sound: the boxed value is
            // read exactly once, for encoding, and never mutated.
            let boxed = ArchiveBox(value.copy() as! NSAttributedString)
            let plain = value.string
            let data = await Task.detached(priority: .userInitiated) { () -> Data? in
                try? NSKeyedArchiver.archivedData(
                    withRootObject: boxed.value,
                    requiringSecureCoding: true
                )
            }.value
            guard !Task.isCancelled else { return }
            applyPersist(plain: plain, data: data)
            hasPendingPersist = false
        }
    }

    /// Synchronous commit of any debounced edits. MUST run before
    /// anything that reads `content` (the splitter on editing end,
    /// view teardown) — the debounce trades a 350 ms staleness
    /// window for keystroke smoothness, and this closes the window.
    private func flushPendingPersist() {
        guard hasPendingPersist else { return }
        persistTask?.cancel()
        persistTask = nil
        hasPendingPersist = false
        remeasureContentHeight()
        persist(attributed)
    }

    private func persist(_ value: NSAttributedString) {
        applyPersist(plain: value.string, data: encodeAttributed(value))
    }

    private func applyPersist(plain: String, data: Data?) {
        // Keep plain text in sync — search, AI prompts, export, and
        // the dictation pipeline all read `content.text` directly.
        let textChanged = content.text != plain
        if textChanged {
            content.text = plain
        }
        // Only write when the encoded payload actually changed so
        // CloudKit doesn't see spurious updates.
        var dataChanged = false
        if let data, content.attributedTextData != data {
            content.attributedTextData = data
            dataChanged = true
        }
        // Nothing actually changed (re-seed echoes, style no-ops):
        // don't stamp updatedAt — a spurious stamp uploads the whole
        // row to CloudKit and re-triggers the hygiene sweep.
        guard textChanged || dataChanged else { return }
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
        NotebookOriginRecorder.markNotebookModified(
            notebookId: element.notebookId,
            context: StorageService.shared.context
        )
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

/// Carries the immutable attributed-string snapshot into the
/// background archive task — see `schedulePersist`. `@unchecked`
/// is sound: the value is written once at init and only ever read.
private struct ArchiveBox: @unchecked Sendable {
    nonisolated(unsafe) let value: NSAttributedString
    nonisolated init(_ value: NSAttributedString) { self.value = value }
}

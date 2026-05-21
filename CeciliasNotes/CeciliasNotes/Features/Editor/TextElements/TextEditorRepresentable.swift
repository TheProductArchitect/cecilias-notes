import SwiftUI
import UIKit

/// `UIViewRepresentable` wrapping a `UITextView` configured for inline
/// page text. Built for `TextElementView` (V6 unified PageElement
/// model). Behaviour deltas vs. SwiftUI's `TextEditor`:
///   • Transparent background — text floats directly on the page
///   • `isScrollEnabled = false` — the element's normalised bounds
///     define the visible area; layout grows downward as content
///     fills, but the view itself doesn't scroll internally
///   • Zero text container insets — tight visual layout
///   • Becomes first responder when `isEditing` flips true; resigns
///     when it flips false
///   • Standard iOS text editing (autocorrect, smart quotes, etc.)
///     per architecture §6 ("iOS standard text editing")
struct TextEditorRepresentable: UIViewRepresentable {

    @Binding var text: String
    let size: TextSize
    @Binding var isEditing: Bool
    let textColor: UIColor

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate                  = context.coordinator
        tv.backgroundColor           = .clear
        tv.isScrollEnabled           = false
        tv.textContainerInset        = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType        = .default
        tv.smartQuotesType           = .yes
        tv.smartDashesType           = .yes
        tv.spellCheckingType         = .default
        tv.keyboardType              = .default
        tv.adjustsFontForContentSizeCategory = false
        // Match SwiftUI's text editor: no internal scroll bounce.
        tv.alwaysBounceVertical      = false
        tv.alwaysBounceHorizontal    = false
        applyStyle(to: tv)
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Gate UIKit interaction on the editing state. An idle text
        // element's UITextView would otherwise win the UIKit
        // hit-test for any touch over its frame — including drags
        // meant for a neighbouring element (e.g. an audio pill that
        // can't be moved when a text box sits nearby). Tap-to-edit
        // is handled by a separate `Color.clear` catcher in the
        // overlay, so the text view only needs interaction while
        // actually editing.
        tv.isUserInteractionEnabled = isEditing

        // Only push the binding into the text view for *external*
        // changes. While the view is first responder the user is
        // typing or dictating into it and the text view is the
        // source of truth — reassigning `tv.text` here would cancel
        // an in-flight dictation session and wipe the text that
        // dictation commits asynchronously after a speech pause.
        if tv.text != text && !tv.isFirstResponder {
            tv.text = text
        }
        applyStyle(to: tv)

        // Drive first-responder from the editing flag — flipping
        // `isEditing = true` in the parent (e.g. cursor tap) makes
        // the keyboard appear; flipping false dismisses it.
        if isEditing && !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isEditing && tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    /// Force SwiftUI to lay out the wrapped UITextView at the
    /// width the parent proposes (which is the `.frame(width:)`
    /// the element view sets to `element.normalizedWidth *
    /// pageSize.width`). Without this, SwiftUI defaults to the
    /// UITextView's `intrinsicContentSize` — which, with
    /// `isScrollEnabled = false`, grows horizontally to fit the
    /// longest unwrapped line. That's the "transcript goes off
    /// the page in one line" bug.
    ///
    /// Implementation: clamp the text container's wrap width to
    /// the proposed width, ask the layout manager for the
    /// resulting glyph rect (which gives us the wrapped height),
    /// and return `(proposedWidth, wrappedHeight)`. SwiftUI then
    /// places the view at that size and the text wraps inside.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth > 0 else {
            return nil
        }
        let newSize = CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        if tv.textContainer.size != newSize {
            tv.textContainer.size = newSize
        }
        // Force layout so usedRect reflects the new wrap width.
        tv.layoutManager.ensureLayout(for: tv.textContainer)
        let used = tv.layoutManager.usedRect(for: tv.textContainer)
        // Height: at least the parent's proposal (so an empty
        // transcript element keeps its initial frame), otherwise
        // the wrapped layout height plus a 1-line breathing
        // buffer so the caret doesn't sit flush against the
        // bottom edge.
        let proposedHeight = proposal.height ?? 0
        let lineBuffer: CGFloat = tv.font.map { $0.lineHeight } ?? 18
        let neededHeight = max(proposedHeight, ceil(used.height) + lineBuffer)
        return CGSize(width: proposedWidth, height: neededHeight)
    }

    private func applyStyle(to tv: UITextView) {
        // Assign only on actual change. Reassigning `tv.font` forces a
        // full glyph re-layout; if that lands mid-dictation it drops
        // the provisional recognition buffer (the "text disappears
        // after a pause" bug). The values are stable across the
        // common re-render, so the guarded assignment is a no-op then.
        let font = UIFont.systemFont(ofSize: size.pointSize, weight: size.fontWeight)
        if tv.font != font {
            tv.font = font
        }
        if tv.textColor != textColor {
            tv.textColor = textColor
        }
        if tv.tintColor != textColor {
            tv.tintColor = textColor  // caret colour follows text colour
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TextEditorRepresentable

        init(_ parent: TextEditorRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isEditing {
                DispatchQueue.main.async { self.parent.isEditing = true }
            }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isEditing {
                DispatchQueue.main.async { self.parent.isEditing = false }
            }
        }
    }
}

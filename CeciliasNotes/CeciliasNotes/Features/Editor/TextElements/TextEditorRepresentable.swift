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
        if tv.text != text {
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

    private func applyStyle(to tv: UITextView) {
        tv.font = UIFont.systemFont(
            ofSize: size.pointSize,
            weight: size.fontWeight
        )
        tv.textColor = textColor
        tv.tintColor = textColor  // caret colour follows text colour
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

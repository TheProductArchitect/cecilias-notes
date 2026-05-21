import SwiftUI
import UIKit

/// `UIViewRepresentable` wrapping a `UITextView` configured for the
/// in-card sticky-note editor. Mirrors `TextEditorRepresentable`
/// (the V6 text element's editor) but with sticky-specific styling:
/// clear background so the card colour shows through, a fixed
/// body-size font, and a dark text colour that reads on every
/// sticky-palette variant without per-colour contrast logic.
struct StickyTextEditor: UIViewRepresentable {

    @Binding var text: String
    @Binding var isEditing: Bool
    let textColor: UIColor

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate                  = context.coordinator
        tv.backgroundColor           = .clear
        tv.isScrollEnabled           = true
        tv.alwaysBounceVertical      = false
        tv.alwaysBounceHorizontal    = false
        tv.showsVerticalScrollIndicator   = false
        tv.showsHorizontalScrollIndicator = false
        tv.textContainerInset        = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType        = .default
        tv.smartQuotesType           = .yes
        tv.smartDashesType           = .yes
        tv.spellCheckingType         = .default
        tv.keyboardType              = .default
        tv.adjustsFontForContentSizeCategory = false
        applyStyle(to: tv)
        tv.text = text
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        // Skip the reassignment while first responder — see
        // `TextEditorRepresentable.updateUIView`. Overwriting
        // `tv.text` mid-dictation cancels the dictation session and
        // drops text committed after a speech pause.
        if tv.text != text && !tv.isFirstResponder {
            tv.text = text
        }
        applyStyle(to: tv)

        if isEditing && !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isEditing && tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    private func applyStyle(to tv: UITextView) {
        // Guarded assignment — reassigning `tv.font` mid-dictation
        // forces a glyph re-layout that drops the provisional
        // recognition buffer. See `TextEditorRepresentable`.
        let font = UIFont.systemFont(ofSize: 15, weight: .regular)
        if tv.font != font {
            tv.font = font
        }
        if tv.textColor != textColor {
            tv.textColor = textColor
        }
        if tv.tintColor != textColor {
            tv.tintColor = textColor
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: StickyTextEditor
        init(_ parent: StickyTextEditor) { self.parent = parent }

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

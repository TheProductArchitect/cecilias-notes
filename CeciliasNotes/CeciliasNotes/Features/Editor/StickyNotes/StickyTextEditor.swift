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
        if tv.text != text {
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
        tv.font      = UIFont.systemFont(ofSize: 15, weight: .regular)
        tv.textColor = textColor
        tv.tintColor = textColor
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

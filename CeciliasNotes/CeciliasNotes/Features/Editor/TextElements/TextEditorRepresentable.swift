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
///   • Rich-text aware: edits an `NSAttributedString` binding and
///     hosts a SwiftUI formatting toolbar as the `inputAccessoryView`
///     when focused (driven by `RichTextController`).
struct TextEditorRepresentable: UIViewRepresentable {

    @Binding var attributed: NSAttributedString
    let size: TextSize
    @Binding var isEditing: Bool
    let textColor: UIColor
    let controller: RichTextController

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
        tv.alwaysBounceVertical      = false
        tv.alwaysBounceHorizontal    = false
        tv.tintColor                 = textColor
        tv.attributedText = attributed
        // typingAttributes must be set *after* attributedText —
        // UIKit clears typingAttributes when attributedText is
        // assigned, so seeding earlier would be wiped out.
        tv.typingAttributes = RichTextController.defaultAttributes(ink: textColor)
        // Install the rich-text toolbar as the input accessory.
        installToolbar(on: tv, context: context)
        // Wire the controller to this text view.
        controller.attach(tv, defaultInk: textColor)
        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        tv.isUserInteractionEnabled = isEditing

        // Push attributed binding into the view only for external
        // mutations and only when not first responder — exact same
        // reasoning as the plain-text predecessor: re-assigning while
        // editing would cancel in-flight dictation/typing.
        if !tv.isFirstResponder, !attributed.isEqual(to: tv.attributedText) {
            tv.attributedText = attributed
        }
        // Keep the default ink + tint colour current with the theme.
        if tv.tintColor != textColor {
            tv.tintColor = textColor
        }
        controller.updateDefaultInk(textColor)

        // Drive first-responder from the editing flag.
        if isEditing && !tv.isFirstResponder {
            DispatchQueue.main.async { tv.becomeFirstResponder() }
        } else if !isEditing && tv.isFirstResponder {
            DispatchQueue.main.async { tv.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView tv: UITextView, context: Context) -> CGSize? {
        guard let proposedWidth = proposal.width, proposedWidth > 0 else {
            return nil
        }
        let newSize = CGSize(width: proposedWidth, height: .greatestFiniteMagnitude)
        if tv.textContainer.size != newSize {
            tv.textContainer.size = newSize
        }
        tv.layoutManager.ensureLayout(for: tv.textContainer)
        let used = tv.layoutManager.usedRect(for: tv.textContainer)
        let proposedHeight = proposal.height ?? 0
        let lineBuffer: CGFloat = tv.font.map { $0.lineHeight } ?? 18
        let neededHeight = max(proposedHeight, ceil(used.height) + lineBuffer)
        return CGSize(width: proposedWidth, height: neededHeight)
    }

    // MARK: - Toolbar wiring

    private func installToolbar(on tv: UITextView, context: Context) {
        let host = UIHostingController(rootView: TextElementToolbar(controller: controller))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        // Size: full width, height matches the toolbar's intrinsic 44pt.
        host.view.frame = CGRect(x: 0, y: 0, width: UIScreen.main.bounds.width, height: 44)
        host.view.autoresizingMask = [.flexibleWidth]
        tv.inputAccessoryView = host.view
        // Retain the hosting controller; without this it gets dropped
        // and SwiftUI updates stop flowing into the accessory view.
        context.coordinator.accessoryHost = host
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: TextEditorRepresentable
        var accessoryHost: UIHostingController<TextElementToolbar>?

        init(_ parent: TextEditorRepresentable) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            // Push the latest attributed text out through the binding.
            // Copy is important — NSTextStorage hands back the live
            // backing store; binding into SwiftUI state with the live
            // pointer leaks future mutations into the source of truth
            // without triggering view updates.
            let snapshot = NSAttributedString(attributedString: textView.attributedText)
            parent.attributed = snapshot
            parent.controller.refresh()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.controller.refresh()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            if !parent.isEditing {
                DispatchQueue.main.async { self.parent.isEditing = true }
            }
            parent.controller.refresh()
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            if parent.isEditing {
                DispatchQueue.main.async { self.parent.isEditing = false }
            }
        }
    }
}

#if os(macOS)
import SwiftUI

extension View {
    /// Hides the default macOS keyboard-focus ring on toolbar and chrome controls.
    func macSuppressFocusRing() -> some View {
        focusEffectDisabled()
    }

    /// Header / popover buttons that should never show the system focus box.
    func macEditorChromeButton() -> some View {
        buttonStyle(.plain)
            .focusEffectDisabled()
            .focusable(false)
    }

    /// Grouped settings forms — suppress focus rings on fields and buttons.
    func macFormFocusChrome() -> some View {
        focusEffectDisabled()
    }
}
#endif

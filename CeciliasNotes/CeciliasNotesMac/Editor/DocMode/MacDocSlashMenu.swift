import AppKit
import SwiftUI

/// Slash-command menu — inline commands (`/summarize`, `/ask`, `/rewrite`,
/// `/continue`) that surface AI actions without leaving the keyboard. The
/// popover is opened by `NSTextView` when the user types `/` at the
/// beginning of a paragraph.
///
/// Also exposes the "AI pill" that appears on text selection so mouse
/// users can reach the same actions without knowing the slash idiom.
struct MacDocSlashMenu: View {
    let onCommand: (Command) -> Void
    var onDismiss: (() -> Void)? = nil
    @Environment(\.theme) private var theme
    @State private var highlighted: Int = 0

    enum Command: String, CaseIterable {
        case summarize, ask, rewrite, continueWriting = "continue"

        var glyph: String {
            switch self {
            case .summarize:       return "sparkles"
            case .ask:             return "bubble.left"
            case .rewrite:         return "arrow.triangle.2.circlepath"
            case .continueWriting: return "text.append"
            }
        }
        var subtitle: String {
            switch self {
            case .summarize:       return "sum up this page"
            case .ask:             return "ask a question about this notebook"
            case .rewrite:         return "rewrite the selected text"
            case .continueWriting: return "continue writing from here"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ai commands")
                .font(.system(size: 8))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Rectangle().fill(theme.hairline).frame(height: 0.5)

            ForEach(Array(Command.allCases.enumerated()), id: \.offset) { index, cmd in
                Button {
                    onCommand(cmd)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: cmd.glyph)
                            .font(.system(size: 12))
                            .foregroundStyle(theme.recessiveTertiary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("/\(cmd.rawValue)")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.foreground)
                            Text(cmd.subtitle)
                                .font(.system(size: 10).italic())
                                .foregroundStyle(theme.recessiveTertiary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(index == highlighted ? theme.surface.opacity(0.5) : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { highlighted = index }
                }
            }
        }
        .frame(width: 300)
        .background(theme.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(theme.hairline, lineWidth: 0.5))
        .focusable()
        .focusEffectDisabled()
        .onAppear {
            highlighted = 0
            DispatchQueue.main.async {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(Command.allCases.count - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.return) {
            selectHighlighted()
            return .handled
        }
        .onKeyPress(.escape) {
            onDismiss?()
            return .handled
        }
    }

    private func selectHighlighted() {
        let commands = Command.allCases
        guard highlighted >= 0, highlighted < commands.count else { return }
        onCommand(commands[highlighted])
    }
}

/// Dictation kick. Uses macOS system dictation (Edit → Start Dictation),
/// which works inside any focused NSTextView with zero implementation
/// cost. On Apple Silicon this is on-device and near-real-time.
@MainActor
enum MacDictationTrigger {
    private static weak var lastFocusedTextView: NSTextView?

    static func register(_ textView: NSTextView) {
        lastFocusedTextView = textView
    }

    static func focusRegisteredTextView() -> Bool {
        guard let textView = lastFocusedTextView else { return false }
        textView.window?.makeFirstResponder(textView)
        return true
    }

    /// Focus the best available `NSTextView`, then ask macOS to start
    /// system dictation on it. Sending `startDictation:` into the void
    /// (`to: nil`) is unreliable and can wedge the app after the mic /
    /// dictation permission sheet dismisses.
    static func start() {
        guard let textView = resolveTargetTextView() else { return }
        textView.window?.makeFirstResponder(textView)
        DispatchQueue.main.async {
            _ = NSApp.sendAction(
                NSSelectorFromString("startDictation:"),
                to: textView,
                from: textView
            )
        }
    }

    private static func resolveTargetTextView() -> NSTextView? {
        if let responder = NSApp.keyWindow?.firstResponder {
            if let textView = responder as? NSTextView { return textView }
            if let textView = findTextView(from: responder) { return textView }
        }
        return lastFocusedTextView
    }

    private static func findTextView(from responder: NSResponder) -> NSTextView? {
        var current: NSResponder? = responder
        while let node = current {
            if let textView = node as? NSTextView { return textView }
            current = node.nextResponder
        }
        return nil
    }
}

/// A floating "AI" pill that appears on text selection inside the doc.
/// Sits above the selection and reveals the same slash-command menu.
struct MacDocAIPill: View {
    let onOpen: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                Text("ask ai")
                    .font(.system(size: 10))
                    .tracking(0.12)
                    .textCase(.uppercase)
            }
            .foregroundStyle(theme.foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.surfaceElevated)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(theme.hairline, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

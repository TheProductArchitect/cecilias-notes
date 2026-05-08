import SwiftUI

// MARK: - InkCommands

/// Real keyboard shortcuts surfaced via `WindowGroup.commands`.
///
/// On iPad with an attached keyboard, ⌘-hold reveals these in the
/// discoverability HUD. On Mac Catalyst they appear in the menu bar.
///
/// Per-screen shortcuts (e.g. ⌘Z undo, ⌘← prev page) are intentionally NOT
/// surfaced here — they live on the editor's own buttons via
/// `.keyboardShortcut(...)` so the system disables them outside the editor.
struct InkCommands: Commands {

    let deepLink: DeepLinkRouter

    var body: some Commands {

        // ⌘N — New Notebook (replaces "New Document")
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") {
                NotificationCenter.default.post(name: .inkCommandNewNotebook, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // ⌘F Search Library — sits next to system Find
        CommandGroup(after: .pasteboard) {
            Button("Search Library") {
                NotificationCenter.default.post(name: .inkCommandSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        // File-style shortcuts. ⌘W returns to Library; ⌘P prints; ⌘⇧E exports.
        // Each posts a notification so the active editor (if any) can react;
        // outside the editor they're harmless no-ops.
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Close Notebook") {
                NotificationCenter.default.post(name: .inkCommandCloseNotebook, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Export…") {
                NotificationCenter.default.post(name: .inkCommandExport, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Print…") {
                NotificationCenter.default.post(name: .inkCommandPrint, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let inkCommandNewNotebook   = Notification.Name("ink.command.newNotebook")
    static let inkCommandSearch        = Notification.Name("ink.command.search")
    static let inkCommandCloseNotebook = Notification.Name("ink.command.closeNotebook")
    static let inkCommandExport        = Notification.Name("ink.command.export")
    static let inkCommandPrint         = Notification.Name("ink.command.print")
}

import SwiftUI

// MARK: - CeciliasNotesCommands

/// Real keyboard shortcuts surfaced via `WindowGroup.commands`.
///
/// On iPad with an attached keyboard, ⌘-hold reveals these in the
/// discoverability HUD. On Mac Catalyst they appear in the menu bar.
///
/// Per-screen shortcuts (e.g. ⌘Z undo, ⌘← prev page) are intentionally NOT
/// surfaced here — they live on the editor's own buttons via
/// `.keyboardShortcut(...)` so the system disables them outside the editor.
struct CeciliasNotesCommands: Commands {

    let deepLink: DeepLinkRouter

    var body: some Commands {

        // ⌘N — New Notebook (replaces "New Document")
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandNewNotebook, object: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
        }

        // ⌘F Search Library — sits next to system Find
        CommandGroup(after: .pasteboard) {
            Button("Search Library") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandSearch, object: nil)
            }
            .keyboardShortcut("f", modifiers: .command)
        }

        // File-style shortcuts. ⌘W returns to Library; ⌘P prints; ⌘⇧E exports.
        // Each posts a notification so the active editor (if any) can react;
        // outside the editor they're harmless no-ops.
        CommandGroup(after: .saveItem) {
            Divider()
            Button("Close Notebook") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandCloseNotebook, object: nil)
            }
            .keyboardShortcut("w", modifiers: .command)

            Button("Export…") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandExport, object: nil)
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])

            Button("Find in Notebook…") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandFindInNotebook, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])

            Button("Print…") {
                NotificationCenter.default.post(name: .ceciliasNotesCommandPrint, object: nil)
            }
            .keyboardShortcut("p", modifiers: .command)
        }
    }
}

// MARK: - Notification names

extension Notification.Name {
    static let ceciliasNotesCommandNewNotebook   = Notification.Name("ceciliasnotes.command.newNotebook")
    static let ceciliasNotesCommandSearch        = Notification.Name("ceciliasnotes.command.search")
    static let ceciliasNotesCommandCloseNotebook = Notification.Name("ceciliasnotes.command.closeNotebook")
    static let ceciliasNotesCommandExport        = Notification.Name("ceciliasnotes.command.export")
    static let ceciliasNotesCommandFindInNotebook = Notification.Name("ceciliasnotes.command.findInNotebook")
    static let ceciliasNotesCommandPrint         = Notification.Name("ceciliasnotes.command.print")
    static let ceciliasNotesQuickCapture         = Notification.Name("ceciliasnotes.command.quickCapture")
}

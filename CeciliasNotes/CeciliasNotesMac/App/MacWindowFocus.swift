import AppKit
import SwiftUI

/// Tags the key window so menu commands can route to library vs editor.
struct MacWindowTag: NSViewRepresentable {
    let identifier: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
    }
}

enum MacEditorPresentation {
    @MainActor static var isInlineActive = false
}

/// Keeps standard traffic-light buttons visible when the editor uses a
/// full-width cover header below the system title bar.
struct MacWindowChromeFix: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.configureWindow(for: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.configureWindow(for: nsView)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        func configureWindow(for view: NSView) {
            DispatchQueue.main.async {
                guard let window = view.window else { return }

                window.titlebarAppearsTransparent = false
                window.titleVisibility = .hidden
                window.toolbar?.displayMode = .iconOnly

                for role: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                    window.standardWindowButton(role)?.isHidden = false
                }
            }
        }
    }
}

enum MacWindowFocus {
    @MainActor
    static var isNotebookEditorKey: Bool {
        MacEditorPresentation.isInlineActive
            || NSApp.keyWindow?.identifier?.rawValue == "notebook-editor"
    }

    @MainActor
    static func bringLibraryForward(andPost notification: Notification.Name? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        let libraryWindow = NSApp.windows.first { window in
            window.canBecomeMain && window.identifier?.rawValue == "library-main"
        } ?? NSApp.windows.first { window in
            window.canBecomeMain && window.identifier?.rawValue != "notebook-editor"
        }
        libraryWindow?.makeKeyAndOrderFront(nil)
        guard let notification else { return }
        MacStateUpdates.deferred {
            NotificationCenter.default.post(name: notification, object: nil)
        }
    }
}

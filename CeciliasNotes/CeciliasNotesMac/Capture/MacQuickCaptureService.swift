import AppKit
import SwiftData
import SwiftUI

/// Menu-bar quick capture — Granola-style title + body popover.
/// Saves to the Unfiled subject (creates it when missing), then opens
/// the new notebook in the main window.
@MainActor
final class MacQuickCaptureController: NSObject, ObservableObject {
    static let shared = MacQuickCaptureController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var globalMonitor: Any?
    private var hotkeyObserver: NSObjectProtocol?

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "square.and.pencil", accessibilityDescription: "Quick capture")
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(togglePopover(_:)),
            name: .macQuickCaptureToggle,
            object: nil
        )

        reinstallGlobalMonitor()

        hotkeyObserver = NotificationCenter.default.addObserver(
            forName: .macCaptureHotkeyChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reinstallGlobalMonitor() }
        }
    }

    private func reinstallGlobalMonitor() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        guard MacCaptureHotkey.current != .disabled else { return }
        let hotkey = MacCaptureHotkey.current
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard hotkey.matches(event) else { return }
            Task { @MainActor in self?.toggle() }
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        toggle()
    }

    func toggle() {
        if popover?.isShown == true {
            close()
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        show()
    }

    func show() {
        guard let button = statusItem?.button else { return }
        let pop = popover ?? {
            let p = NSPopover()
            p.contentSize = NSSize(width: 360, height: 280)
            p.behavior = .transient
            p.animates = true
            p.contentViewController = NSHostingController(
                rootView: MacQuickCaptureView(onSave: { [weak self] in self?.close() })
                    .environment(\.theme, ThemeManager.shared.current)
            )
            self.popover = p
            return p
        }()
        pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func close() {
        popover?.performClose(nil)
    }
}

/// Persists a quick-capture note into the Unfiled subject.
@MainActor
enum MacQuickCaptureSave {
    static func save(title: String, body: String) -> UUID? {
        guard let notebookId = QuickCaptureSave.save(title: title, body: body) else { return nil }
        NotificationCenter.default.post(
            name: .macOpenNotebook,
            object: nil,
            userInfo: [MacHandoff.notebookIdKey: notebookId]
        )
        return notebookId
    }
}

struct MacQuickCaptureView: View {
    @Environment(\.theme) private var theme
    @State private var title = ""
    @State private var bodyText = ""
    @FocusState private var titleFocused: Bool
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("quick capture")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveTertiary)

            TextField("title", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 17, weight: .heavy))
                .focused($titleFocused)

            TextEditor(text: $bodyText)
                .font(.system(size: 13).italic())
                .frame(minHeight: 120)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if bodyText.isEmpty {
                        Text("what's on your mind?")
                            .font(.system(size: 13).italic())
                            .foregroundStyle(theme.recessiveQuaternary)
                            .padding(.top, 8)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }

            HStack {
                Spacer()
                Button("Save to Unfiled") { save() }
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 360, height: 280)
        .background(theme.surfaceElevated)
        .onAppear { titleFocused = true }
    }

    private func save() {
        guard MacQuickCaptureSave.save(title: title, body: bodyText) != nil else { return }
        onSave()
    }
}

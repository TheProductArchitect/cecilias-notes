import SwiftData
import SwiftUI

struct MacAppCommands: Commands {
    @ObservedObject private var menuState = MacMenuState.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Notebook") { NotificationCenter.default.post(name: .macNewNotebook, object: nil) }
                .keyboardShortcut("n")
            Button("New Subject") {
                NotificationCenter.default.post(name: .macNewSubject, object: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Menu("New from Template") {
                ForEach(MacNotebookTemplate.allCases) { template in
                    Button(template.menuTitle) {
                        NotificationCenter.default.post(
                            name: .macNewFromTemplate,
                            object: nil,
                            userInfo: [MacTemplateHandoff.templateKey: template.rawValue]
                        )
                    }
                }
            }
            Divider()
            if menuState.recentNotebooks.isEmpty {
                Button("Open Recent") { }
                    .disabled(true)
            } else {
                Menu("Open Recent") {
                    ForEach(menuState.recentNotebooks) { item in
                        Button(item.title) { menuState.openNotebook(id: item.id) }
                    }
                }
            }
            Button("Open Most Recent") { menuState.openMostRecent() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(menuState.recentNotebooks.isEmpty)
            Button("Export…") { NotificationCenter.default.post(name: .macExport, object: nil) }
                .keyboardShortcut("e")
            Button("Print…") { NotificationCenter.default.post(name: .macPrint, object: nil) }
                .keyboardShortcut("p")
        }
        CommandMenu("Find") {
            Button("Search Library…") {
                NotificationCenter.default.post(name: .macOpenSearch, object: nil)
            }
            .keyboardShortcut("f")
            Button("Search in Notebook…") {
                NotificationCenter.default.post(name: .macSearchInNotebook, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") {
                NotificationCenter.default.post(name: .macToggleSidebar, object: nil)
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
        }
        CommandGroup(after: .undoRedo) {
            Button("Insert Text") { NotificationCenter.default.post(name: .macInsertText, object: nil) }
                .keyboardShortcut("t")
            Button("Insert Image…") {
                NotificationCenter.default.post(name: .macInsertImage, object: nil)
            }
            Button("Insert Sticky Note") {
                NotificationCenter.default.post(name: .macInsertStickyNote, object: nil)
            }
            Menu("Insert Shape") {
                Button("Rectangle") {
                    postInsertShape(.rectangle)
                }
                Button("Ellipse") {
                    postInsertShape(.ellipse)
                }
                Button("Arrow") {
                    postInsertShape(.arrow)
                }
            }
            Button("Summarize Page") {
                NotificationCenter.default.post(name: .macSummarizePage, object: nil)
            }
            Button("Ask About Page") {
                NotificationCenter.default.post(name: .macAskAboutPage, object: nil)
            }
            Button("Page Template…") {
                NotificationCenter.default.post(name: .macPageTemplate, object: nil)
            }
            Button("Import PDF Pages…") {
                NotificationCenter.default.post(name: .macImportPDFPages, object: nil)
            }
            Button("Copy Handwriting as Text") {
                NotificationCenter.default.post(name: .macCopyHandwritingOCR, object: nil)
            }
            Button("Generate Quiz…") {
                NotificationCenter.default.post(name: .macGenerateQuiz, object: nil)
            }
            Divider()
            Button("Copy Page as Image") {
                NotificationCenter.default.post(name: .macCopyPage, object: nil)
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
        }
        CommandMenu("Page") {
            Button("Add Page") {
                NotificationCenter.default.post(name: .macAddPage, object: nil)
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Duplicate Page") {
                NotificationCenter.default.post(name: .macDuplicatePage, object: nil)
            }
            Button("Reorder Pages…") {
                NotificationCenter.default.post(name: .macReorderPages, object: nil)
            }
            Button("Move Page Up") {
                NotificationCenter.default.post(name: .macMovePageUp, object: nil)
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Move Page Down") {
                NotificationCenter.default.post(name: .macMovePageDown, object: nil)
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("Delete Page") {
                NotificationCenter.default.post(name: .macDeletePage, object: nil)
            }
        }
        CommandMenu("View") {
            Button("Zoom In") {
                NotificationCenter.default.post(name: .macZoomIn, object: nil)
            }
            .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") {
                NotificationCenter.default.post(name: .macZoomOut, object: nil)
            }
            .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") {
                NotificationCenter.default.post(name: .macZoomReset, object: nil)
            }
            .keyboardShortcut("0")
            Button("Focus Mode") {
                NotificationCenter.default.post(name: .macToggleFocusMode, object: nil)
            }
            .keyboardShortcut("f", modifiers: [.command, .control])
            Button("Quick Capture") {
                NotificationCenter.default.post(name: .macQuickCaptureToggle, object: nil)
            }
            .keyboardShortcut(" ", modifiers: [.command, .option])
        }
        CommandMenu("Navigate") {
            Button("Command Palette…") {
                NotificationCenter.default.post(name: .macOpenCommandPalette, object: nil)
            }
            .keyboardShortcut("k")
            Divider()
            Button("Select Next Element") {
                NotificationCenter.default.post(name: .macSelectNextElement, object: nil)
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            Button("Select Previous Element") {
                NotificationCenter.default.post(name: .macSelectPreviousElement, object: nil)
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Delete Selected Element") {
                NotificationCenter.default.post(name: .macDeleteSelectedElement, object: nil)
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") {
                NotificationCenter.default.post(name: .macOpenSettings, object: nil)
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private func postInsertShape(_ kind: ShapeKind) {
        NotificationCenter.default.post(
            name: .macInsertShape,
            object: nil,
            userInfo: [MacShapeHandoff.kindKey: kind.rawValue]
        )
    }
}

extension Notification.Name {
    static let macNewNotebook = Notification.Name("app.ceciliasnotes.mac.newNotebook")
    static let macExport = Notification.Name("app.ceciliasnotes.mac.export")
    static let macInsertText = Notification.Name("app.ceciliasnotes.mac.insertText")
    static let macOpenSettings = Notification.Name("app.ceciliasnotes.mac.openSettings")
    static let macOpenSearch = Notification.Name("app.ceciliasnotes.mac.openSearch")
    static let macToggleSidebar = Notification.Name("app.ceciliasnotes.mac.toggleSidebar")
    static let macZoomReset = Notification.Name("app.ceciliasnotes.mac.zoomReset")
    static let macZoomIn = Notification.Name("app.ceciliasnotes.mac.zoomIn")
    static let macZoomOut = Notification.Name("app.ceciliasnotes.mac.zoomOut")
    static let macSummarizePage = Notification.Name("app.ceciliasnotes.mac.summarizePage")
    static let macQuickCaptureToggle = Notification.Name("app.ceciliasnotes.mac.quickCaptureToggle")
    static let macCaptureHotkeyChanged = Notification.Name("app.ceciliasnotes.mac.captureHotkeyChanged")
    static let macOpenCommandPalette = Notification.Name("app.ceciliasnotes.mac.openCommandPalette")
    static let macOpenNotebook = Notification.Name("app.ceciliasnotes.mac.openNotebook")
    static let macNewSubject = Notification.Name("app.ceciliasnotes.mac.newSubject")
    static let macPrint = Notification.Name("app.ceciliasnotes.mac.print")
    static let macAskAboutPage = Notification.Name("app.ceciliasnotes.mac.askAboutPage")
    static let macPageTemplate = Notification.Name("app.ceciliasnotes.mac.pageTemplate")
    static let macAddPage = Notification.Name("app.ceciliasnotes.mac.addPage")
    static let macDeletePage = Notification.Name("app.ceciliasnotes.mac.deletePage")
    static let macDuplicatePage = Notification.Name("app.ceciliasnotes.mac.duplicatePage")
    static let macReorderPages = Notification.Name("app.ceciliasnotes.mac.reorderPages")
    static let macMovePageUp = Notification.Name("app.ceciliasnotes.mac.movePageUp")
    static let macMovePageDown = Notification.Name("app.ceciliasnotes.mac.movePageDown")
    static let macInsertShape = Notification.Name("app.ceciliasnotes.mac.insertShape")
    static let macSearchInNotebook = Notification.Name("app.ceciliasnotes.mac.searchInNotebook")
    static let macGenerateQuiz = Notification.Name("app.ceciliasnotes.mac.generateQuiz")
    static let macCopyPage = Notification.Name("app.ceciliasnotes.mac.copyPage")
    static let macNewFromTemplate = Notification.Name("app.ceciliasnotes.mac.newFromTemplate")
    static let macToggleFocusMode = Notification.Name("app.ceciliasnotes.mac.toggleFocusMode")
    static let macInsertImage = Notification.Name("app.ceciliasnotes.mac.insertImage")
    static let macInsertStickyNote = Notification.Name("app.ceciliasnotes.mac.insertStickyNote")
    static let macSelectNextElement = Notification.Name("app.ceciliasnotes.mac.selectNextElement")
    static let macSelectPreviousElement = Notification.Name("app.ceciliasnotes.mac.selectPreviousElement")
    static let macDeleteSelectedElement = Notification.Name("app.ceciliasnotes.mac.deleteSelectedElement")
    static let macImportPDFPages = Notification.Name("app.ceciliasnotes.mac.importPDFPages")
    static let macCopyHandwritingOCR = Notification.Name("app.ceciliasnotes.mac.copyHandwritingOCR")
}

enum MacTemplateHandoff {
    static let templateKey = "template"
}

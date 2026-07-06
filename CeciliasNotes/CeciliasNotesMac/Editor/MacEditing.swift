import AppKit
import SwiftData
import SwiftUI

@MainActor
enum MacElementEditing {
    static func insertText(
        on page: Page,
        notebookId: UUID,
        context: ModelContext
    ) -> PageElement? {
        TextElementCommit.create(
            text: "",
            source: .typed,
            pageId: page.id,
            notebookId: notebookId,
            normalizedRect: CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.12),
            context: context
        )
    }

    static func updateTextContent(
        _ element: PageElement,
        plain: String,
        attributedData: Data?,
        context: ModelContext
    ) {
        guard element.kind == .text, let content = element.textContent else { return }
        content.text = plain
        content.attributedTextData = attributedData
        content.updatedAt = Date()
        element.updatedAt = Date()
        try? context.save()
        touchNotebook(for: element, context: context)
        MultipeerNotebookHint.broadcastNotebookChanged(notebookId: element.notebookId)
    }

    private static func touchNotebook(for element: PageElement, context: ModelContext) {
        let notebookId = element.notebookId
        var descriptor = FetchDescriptor<Notebook>(
            predicate: #Predicate { $0.id == notebookId && !$0.isDeleted }
        )
        descriptor.fetchLimit = 1
        if let notebook = try? context.fetch(descriptor).first {
            notebook.markModified()
            try? context.save()
        }
    }

    static func updateText(_ element: PageElement, text: String, context: ModelContext) {
        updateTextContent(element, plain: text, attributedData: nil, context: context)
    }

    static func softDelete(_ element: PageElement, context: ModelContext) {
        let now = Date()
        element.deletedAt = now
        element.updatedAt = now
        try? context.save()
    }

    static func insertShape(
        kind: ShapeKind,
        on page: Page,
        notebookId: UUID,
        context: ModelContext
    ) -> PageElement? {
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.zIndex, order: .reverse)]
        )
        let maxZ = (try? context.fetch(descriptor))?.first?.zIndex ?? 0
        let element = PageElement(
            pageId: page.id,
            notebookId: notebookId,
            kind: .shape,
            normalizedX: 0.30,
            normalizedY: 0.30,
            normalizedWidth: 0.40,
            normalizedHeight: 0.22,
            zIndex: maxZ + 1
        )
        let content = ShapeContent(
            shapeKind: kind,
            strokeColorHex: "",
            strokeWidth: 2,
            strokeStyle: .solid
        )
        element.shapeContent = content
        context.insert(element)
        try? context.save()
        NotificationCenter.default.post(name: .shapeElementsChanged, object: nil)
        return element
    }

    @discardableResult
    static func insertStickyNote(
        on page: Page,
        notebookId: UUID,
        pageSize: CGSize,
        context: ModelContext
    ) -> PageElement? {
        guard pageSize.width > 0, pageSize.height > 0 else { return nil }
        let cardSize = CGSize(width: 160, height: 120)
        let normW = Double(cardSize.width / pageSize.width)
        let normH = Double(cardSize.height / pageSize.height)
        let center = CGPoint(x: 0.5, y: 0.35)
        let halfW = normW / 2
        let halfH = normH / 2
        let cx = max(halfW, min(1 - halfW, Double(center.x)))
        let cy = max(halfH, min(1 - halfH, Double(center.y)))
        let pid = page.id
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pid && $0.deletedAt == nil }
        )
        let maxZ = ((try? context.fetch(descriptor)) ?? [])
            .filter { $0.kind == .stickyNote }
            .map(\.zIndex).max() ?? 0
        let element = PageElement(
            pageId: page.id,
            notebookId: notebookId,
            kind: .stickyNote,
            normalizedX: cx - halfW,
            normalizedY: cy - halfH,
            normalizedWidth: normW,
            normalizedHeight: normH,
            zIndex: maxZ + 1
        )
        element.stickyNoteContent = StickyNoteContent(text: "", colorVariant: "yellow")
        context.insert(element)
        try? context.save()
        return element
    }

    static func pickAndInsertImage(
        on page: Page,
        notebookId: UUID,
        context: ModelContext
    ) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .png, .jpeg, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            _ = await MacImportService.importImageURL(
                url,
                pageId: page.id,
                notebookId: notebookId,
                context: context
            )
        }
    }
}

extension Notification.Name {
    static let shapeElementsChanged = Notification.Name("editor.shapeElementsChanged")
}

@MainActor
enum MacNotebookCustomization {
    static func rename(_ notebook: Notebook, title: String, storage: StorageService) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != notebook.title else { return }
        try? storage.updateNotebook(
            notebook,
            title: trimmed,
            coverColorHex: nil,
            isPinned: nil,
            tags: nil
        )
    }

    static func applyPageSize(_ size: PageSize, notebook: Notebook, storage: StorageService) {
        try? storage.updateNotebook(
            notebook,
            title: nil,
            coverColorHex: nil,
            isPinned: nil,
            tags: nil,
            pageSize: size
        )
        if let first = storage.fetchPages(in: notebook).first(where: { $0.pageNumber == 1 }),
           storage.strokeData(for: first)?.isEmpty ?? true {
            first.pageSize = size
            first.updatedAt = Date()
            try? storage.context.save()
        }
        UserDefaults.standard.set(size.rawValue, forKey: "ceciliasnotes.lastUsed.pageSize")
    }

    static func applyDefaultTemplate(_ template: PageTemplate, notebook: Notebook, storage: StorageService) {
        try? storage.updateNotebook(
            notebook,
            title: nil,
            coverColorHex: nil,
            isPinned: nil,
            tags: nil,
            defaultTemplate: template
        )
    }
}

@MainActor
enum MacPageEditing {
    @discardableResult
    static func addPage(
        in notebook: Notebook,
        after page: Page?,
        storage: StorageService
    ) -> Page? {
        try? storage.createPage(
            in: notebook,
            after: page?.pageNumber,
            pageSize: notebook.pageSize,
            backgroundTemplate: notebook.defaultTemplate
        )
    }

    static func deletePage(_ page: Page, notebook: Notebook, storage: StorageService) -> Bool {
        let pages = storage.fetchPages(in: notebook)
        guard pages.count > 1 else { return false }
        try? storage.deletePage(page)
        return true
    }

    static func duplicatePage(_ page: Page, storage: StorageService) -> Page? {
        try? storage.duplicatePage(page)
    }

    static func movePage(_ page: Page, to targetPageNumber: Int, storage: StorageService) -> Bool {
        (try? storage.movePage(page, to: targetPageNumber)) != nil
    }
}
struct MacStickyNoteEditorSheet: View {
    let element: PageElement
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storageService: StorageService
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("sticky note")
                .font(.system(size: 8, weight: .regular))
                .tracking(0.12)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 120)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    element.stickyNoteContent?.text = draft
                    element.stickyNoteContent?.updatedAt = Date()
                    element.updatedAt = Date()
                    try? storageService.context.save()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 360, height: 240)
        .onAppear { draft = element.stickyNoteContent?.text ?? "" }
    }
}

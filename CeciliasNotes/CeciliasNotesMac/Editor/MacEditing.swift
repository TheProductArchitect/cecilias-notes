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

    static func updateText(_ element: PageElement, text: String, context: ModelContext) {
        guard element.kind == .text, let content = element.textContent else { return }
        content.text = text
        content.updatedAt = Date()
        element.updatedAt = Date()
        try? context.save()
    }

    static func softDelete(_ element: PageElement, context: ModelContext) {
        let now = Date()
        element.deletedAt = now
        element.updatedAt = now
        try? context.save()
    }
}

struct MacTextEditorSheet: View {
    let element: PageElement
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var storageService: StorageService
    @State private var draft: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Text").font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 160)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    MacElementEditing.updateText(element, text: draft, context: storageService.context)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 420, height: 280)
        .onAppear { draft = element.textContent?.text ?? "" }
    }
}

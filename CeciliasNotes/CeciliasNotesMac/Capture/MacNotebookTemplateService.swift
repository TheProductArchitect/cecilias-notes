import SwiftData
import SwiftUI

enum MacNotebookTemplate: String, CaseIterable, Identifiable {
    case meeting
    case lecture
    case journal

    var id: String { rawValue }

    var menuTitle: String {
        switch self {
        case .meeting:  return "Meeting Notes"
        case .lecture:  return "Lecture Notes"
        case .journal:  return "Journal Entry"
        }
    }

    var defaultTitle: String {
        switch self {
        case .meeting:  return "Meeting"
        case .lecture:  return "Lecture"
        case .journal:  return "Journal"
        }
    }

    private var blocks: [(String, CGFloat)] {
        switch self {
        case .meeting:
            return [
                ("agenda", 0.08),
                ("attendees", 0.22),
                ("notes", 0.38),
                ("action items", 0.62),
            ]
        case .lecture:
            return [
                ("topic", 0.08),
                ("key points", 0.24),
                ("questions", 0.50),
            ]
        case .journal:
            return [
                ("today", 0.10),
                ("grateful for", 0.30),
                ("on my mind", 0.52),
            ]
        }
    }

    @MainActor
    static func create(
        _ template: MacNotebookTemplate,
        libraryVM: LibraryViewModel,
        storage: StorageService
    ) -> UUID? {
        let cover = NotebookCover.from(
            rawValue: UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.cover")
        )
        let pageSize: PageSize = {
            if let raw = UserDefaults.standard.string(forKey: "ceciliasnotes.lastUsed.pageSize"),
               let value = PageSize(rawValue: raw) { return value }
            return .a4
        }()

        guard let notebook = try? storage.createNotebook(
            title: template.defaultTitle,
            subjectId: libraryVM.selectedSubjectId,
            coverColorHex: cover.colorHex,
            coverTexture: cover.texture,
            pageSize: pageSize,
            template: .narrowRuled
        ) else { return nil }

        guard let page = storage.fetchPages(in: notebook).first else { return notebook.id }

        for (heading, y) in template.blocks {
            let text = "\(heading)\n"
            _ = TextElementCommit.create(
                text: text,
                source: .typed,
                pageId: page.id,
                notebookId: notebook.id,
                normalizedRect: CGRect(x: 0.08, y: y, width: 0.84, height: 0.12),
                context: storage.context
            )
        }

        try? storage.context.save()
        libraryVM.refresh()
        NewNotebookCustomiseTrigger.mark(notebook.id)
        libraryVM.selectedNotebookId = notebook.id
        return notebook.id
    }
}

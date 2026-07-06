import Foundation
import CoreGraphics
import SwiftData

/// JSON payload written by the share extension for text / URL shares.
/// File extension: `.cnshare` in the app-group ShareInbox folder.
struct ShareCapturePayload: Codable, Sendable {
    let title: String
    let body: String

    static let fileExtension = "cnshare"
}

/// Saves a title + body into a new notebook under Unfiled (creates
/// the subject when missing). Shared by Mac quick capture, Services
/// menu, and the iOS share-extension text path.
@MainActor
enum QuickCaptureSave {

    @discardableResult
    static func save(title: String, body: String) -> UUID? {
        let storage = StorageService.shared
        let context = storage.context
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty || !trimmedBody.isEmpty else { return nil }

        let subjectId = unfiledSubjectId(context: context)
        let notebookTitle = trimmedTitle.isEmpty ? "Capture" : trimmedTitle

        let notebook = Notebook(
            title: notebookTitle,
            subjectId: subjectId,
            coverColorHex: "#FAFAF8",
            pageSize: .a4
        )
        context.insert(notebook)

        let page = Page(
            notebookId: notebook.id,
            pageNumber: 1,
            pageSize: .a4,
            backgroundTemplate: .blank
        )
        context.insert(page)
        notebook.pages = [page]

        if !trimmedBody.isEmpty {
            _ = TextElementCommit.create(
                text: trimmedBody,
                source: .typed,
                pageId: page.id,
                notebookId: notebook.id,
                normalizedRect: CGRect(x: 0.08, y: 0.10, width: 0.84, height: 0.35),
                context: context
            )
        }

        do {
            try context.save()
        } catch {
            return nil
        }

        RecentNotebooksTracker.markOpened(notebook.id)
        return notebook.id
    }

    private static func unfiledSubjectId(context: ModelContext) -> UUID? {
        let descriptor = FetchDescriptor<Subject>(
            predicate: #Predicate { $0.isDeleted == false }
        )
        let subjects = (try? context.fetch(descriptor)) ?? []
        if let unfiled = subjects.first(where: { $0.name.lowercased() == "unfiled" }) {
            return unfiled.id
        }
        let subject = Subject(
            name: "Unfiled",
            colorHex: CeciliasNotesColorPresets.subjectColors.first ?? "#7F7F7F",
            sortOrder: subjects.count
        )
        context.insert(subject)
        return subject.id
    }
}

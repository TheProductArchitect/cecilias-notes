import Foundation
import SwiftData

extension ModelContainer {
    /// Production container backed by ink.sqlite in Application Support/Ink/.
    static func inkContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ])
        let storeURL = StorageService.inkDirectoryURL
            .appendingPathComponent("ink.sqlite")
        try FileManager.default.createDirectory(
            at: StorageService.inkDirectoryURL,
            withIntermediateDirectories: true
        )
        let config = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: config)
    }

    /// In-memory container for unit tests — no disk I/O.
    static func inkTestContainer() throws -> ModelContainer {
        let schema = Schema([
            Subject.self,
            Notebook.self,
            Page.self,
            TextBlock.self,
            MediaAttachment.self,
            AudioAnnotation.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: config)
    }
}

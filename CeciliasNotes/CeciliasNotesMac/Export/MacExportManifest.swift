import Foundation

// Shared with iPad — same manifest file so exports appear in Recent Exports on both platforms.

struct ExportRecord: Codable, Identifiable, Sendable {
    var id: UUID
    var notebookId: UUID
    var notebookTitle: String
    var fileURL: URL
    var fileSizeBytes: Int64
    var pageCount: Int
    var exportedAt: Date

    init(
        notebookId: UUID,
        notebookTitle: String,
        fileURL: URL,
        fileSizeBytes: Int64,
        pageCount: Int,
        exportedAt: Date
    ) {
        self.id = UUID()
        self.notebookId = notebookId
        self.notebookTitle = notebookTitle
        self.fileURL = fileURL
        self.fileSizeBytes = fileSizeBytes
        self.pageCount = pageCount
        self.exportedAt = exportedAt
    }

    nonisolated var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var formattedDate: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: exportedAt)
    }
}

actor ExportManifest {
    static let shared = ExportManifest()

    private static let maxRecords = 10
    private static var manifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CeciliasNotes")
            .appendingPathComponent("exports_manifest.json")
    }

    private var records: [ExportRecord] = []
    private var loaded = false

    func loadedRecords() async -> [ExportRecord] {
        await ensureLoaded()
        return records
    }

    func append(_ record: ExportRecord) async {
        await ensureLoaded()
        records.removeAll { $0.notebookId == record.notebookId && $0.fileURL == record.fileURL }
        records.insert(record, at: 0)
        if records.count > Self.maxRecords {
            records = Array(records.prefix(Self.maxRecords))
        }
        save()
    }

    func delete(id: UUID) async {
        await ensureLoaded()
        if let record = records.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: record.fileURL)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func refresh() async {
        await ensureLoaded()
        records = records.filter { $0.fileExists }
        save()
    }

    private func ensureLoaded() async {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: Self.manifestURL) else { return }
        records = (try? JSONDecoder().decode([ExportRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        let dir = Self.manifestURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: Self.manifestURL, options: .atomic)
    }
}

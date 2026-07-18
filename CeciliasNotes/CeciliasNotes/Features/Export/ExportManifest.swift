import Foundation

// MARK: - ExportRecord

struct ExportRecord: Codable, Identifiable, Sendable {
    var id:            UUID
    var notebookId:    UUID
    var notebookTitle: String
    var fileURL:       URL
    var fileSizeBytes: Int64
    var pageCount:     Int
    var exportedAt:    Date

    init(
        notebookId:    UUID,
        notebookTitle: String,
        fileURL:       URL,
        fileSizeBytes: Int64,
        pageCount:     Int,
        exportedAt:    Date
    ) {
        self.id            = UUID()
        self.notebookId    = notebookId
        self.notebookTitle = notebookTitle
        self.fileURL       = fileURL
        self.fileSizeBytes = fileSizeBytes
        self.pageCount     = pageCount
        self.exportedAt    = exportedAt
    }

    /// The stored absolute `fileURL` is only valid inside the sandbox
    /// container that wrote it — iOS rotates the container UUID on
    /// every reinstall/update, which stranded every record: the file
    /// migrates to the new container, the recorded path doesn't, so
    /// `refresh()` pruned the whole manifest and Recent Exports sat
    /// empty despite fresh exports. Resolve by filename against the
    /// CURRENT exports directory whenever the stored path is dead.
    nonisolated var resolvedURL: URL {
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        return ExportService.globalExportsDirectory
            .appendingPathComponent(fileURL.lastPathComponent)
    }

    /// `nonisolated` so the property reads cleanly from any actor —
    /// `FileManager.default.fileExists(atPath:)` is thread-safe.
    nonisolated var fileExists: Bool {
        FileManager.default.fileExists(atPath: resolvedURL.path)
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

// MARK: - ExportManifest

/// Persists the last 10 export records to a JSON file.
/// All reads/writes happen on this actor's executor.
actor ExportManifest {

    static let shared = ExportManifest()

    private static let maxRecords = 10
    private static var manifestURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CeciliasNotes")
            .appendingPathComponent("exports_manifest.json")
    }

    private var records: [ExportRecord] = []
    private var loaded  = false

    // MARK: - Public API

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
            try? FileManager.default.removeItem(at: record.resolvedURL)
        }
        records.removeAll { $0.id == id }
        save()
    }

    func refresh() async {
        await ensureLoaded()
        // Remove stale records pointing to deleted files
        records = records.filter { $0.fileExists }
        save()
    }

    // MARK: - Private

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

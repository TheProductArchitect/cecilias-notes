import Social
import UIKit
import UniformTypeIdentifiers

/// Cecilia's Notes share-extension entry point. Accepts PDFs and
/// images from any host app (Files, Photos, Safari, Mail) and drops
/// them into the shared app-group ShareInbox folder. The main app
/// watches that folder on foreground / launch and ingests anything
/// it finds — same mental model as the MCP inbox, just sourced from
/// the system share sheet.
///
/// Storage location:
///   `<app-group-container>/ShareInbox/<uuid>.<ext>`
///
/// The main app must:
///   1. Subscribe to `UIApplication.didBecomeActiveNotification` (or
///      the equivalent in `RootView.task`).
///   2. List the ShareInbox directory.
///   3. For each file, decide: PDF → present the PDF page picker,
///      image → add as PageElement on the current notebook page (or
///      ask the user where).
///   4. Delete the file after successful ingest.
final class ShareViewController: SLComposeServiceViewController {

    private static let appGroupID = "group.app.ceciliasnotes"
    private static let inboxFolderName = "ShareInbox"

    override func isContentValid() -> Bool {
        // The share sheet always knows what type the source is; we
        // accept any attachment up front and reject only when no
        // file-bearing item is attached at all.
        guard let items = extensionContext?.inputItems as? [NSExtensionItem]
        else { return false }
        return items.contains { ($0.attachments ?? []).isEmpty == false }
    }

    override func didSelectPost() {
        Task { await ingestAttachments() }
    }

    override func configurationItems() -> [Any]! { [] }

    // MARK: - Ingest

    private func ingestAttachments() async {
        defer {
            extensionContext?.completeRequest(
                returningItems: [],
                completionHandler: nil
            )
        }
        guard let inboxURL = inboxURL() else { return }

        let attachments = (extensionContext?.inputItems as? [NSExtensionItem])?
            .flatMap { $0.attachments ?? [] } ?? []

        for provider in attachments {
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
                await writeAttachment(
                    provider: provider,
                    typeID: UTType.pdf.identifier,
                    suggestedExt: "pdf",
                    inbox: inboxURL
                )
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let ext = preferredImageExtension(for: provider)
                await writeAttachment(
                    provider: provider,
                    typeID: UTType.image.identifier,
                    suggestedExt: ext,
                    inbox: inboxURL
                )
            }
        }
    }

    private func writeAttachment(
        provider: NSItemProvider,
        typeID: String,
        suggestedExt: String,
        inbox: URL
    ) async {
        let item: NSSecureCoding?
        do {
            item = try await provider.loadItem(forTypeIdentifier: typeID, options: nil)
        } catch {
            return
        }

        let destination = inbox.appendingPathComponent(
            "\(UUID().uuidString).\(suggestedExt)"
        )

        if let url = item as? URL {
            // File-URL attachments (Files app, Mail): copy into inbox.
            try? FileManager.default.copyItem(at: url, to: destination)
        } else if let data = item as? Data {
            try? data.write(to: destination, options: .atomic)
        } else if let image = item as? UIImage,
                  let data = image.pngData() {
            try? data.write(to: destination, options: .atomic)
        }
    }

    private func preferredImageExtension(for provider: NSItemProvider) -> String {
        if provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) {
            return "png"
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.heic.identifier) {
            return "heic"
        }
        return "jpg"
    }

    private func inboxURL() -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupID
        ) else { return nil }
        let inbox = container.appendingPathComponent(
            Self.inboxFolderName,
            isDirectory: true
        )
        try? FileManager.default.createDirectory(
            at: inbox,
            withIntermediateDirectories: true
        )
        return inbox
    }
}

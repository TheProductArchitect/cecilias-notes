import UIKit
import UniformTypeIdentifiers

/// Cecilia's Notes share-extension entry point. Accepts PDFs and
/// images from any host app (Files, Photos, Safari, Mail) and drops
/// them into the shared app-group `ShareInbox` folder. The main app
/// watches that folder on foreground / launch and ingests anything
/// it finds.
///
/// Design: this is intentionally a plain `UIViewController` rather
/// than `SLComposeServiceViewController`. The compose-style sheet
/// is for share targets that take user input (a tweet, a message);
/// our flow has no input — we just save and exit. Showing a
/// "saving…" label for a moment and dismissing automatically reads
/// better than an empty compose form.
///
/// Storage location:
///   `<app-group-container>/ShareInbox/<uuid>.<ext>`
final class ShareViewController: UIViewController {

    private static let appGroupID = "group.app.ceciliasnotes"
    private static let inboxFolderName = "ShareInbox"

    override func viewDidLoad() {
        super.viewDidLoad()
        // Empty surface — we never want the extension UI to be
        // visible. The view exists because UIViewController needs
        // one; it just renders a clear/system background for the
        // brief moment between viewDidLoad and the deep-link open.
        view.backgroundColor = .systemBackground
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await ingestAndComplete() }
    }

    // MARK: - Ingest

    private func ingestAndComplete() async {
        // Save the file to the app-group inbox, then deep-link into
        // the main app immediately. No spinner, no "Saved." label,
        // no animated wait — the user picked Cecilia's Notes from
        // the share sheet, they don't need a confirmation screen.
        // The main app foregrounds and the picker appears in one
        // continuous motion.
        await ingestAttachments()
        await MainActor.run {
            let deepLink = URL(string: "ceciliasnotes://library")!
            self.extensionContext?.open(deepLink) { [weak self] _ in
                Task { @MainActor in
                    self?.extensionContext?.completeRequest(
                        returningItems: nil,
                        completionHandler: nil
                    )
                }
            }
        }
    }

    private func ingestAttachments() async {
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

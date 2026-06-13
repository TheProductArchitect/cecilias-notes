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

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.startAnimating()
        return s
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Minimal-but-visible surface. Earlier we tried rendering
        // nothing at all to make the extension feel instant, but
        // iOS appears to treat a content-less extension view as
        // broken and silently aborts the request — no
        // `completeRequest` log, no `open` callback, the share
        // sheet just hangs. A bare centred spinner is enough for
        // the system to consider the UI "real," and it dismisses
        // fast enough that the user perceives the share as
        // instant.
        view.backgroundColor = .systemBackground
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await ingestAndComplete() }
    }

    // MARK: - Ingest

    private func ingestAndComplete() async {
        // Save the file to the app-group inbox, then deep-link into
        // the main app. `completeRequest` runs unconditionally
        // right after the open call — we used to chain it inside
        // `open`'s completion handler, but iOS doesn't always fire
        // that callback (especially when the open is queued or
        // partially rejected), leaving the extension stuck.
        // Calling both in sequence dismisses the share sheet
        // reliably regardless of whether the deep link landed.
        await ingestAttachments()
        await MainActor.run {
            let deepLink = URL(string: "ceciliasnotes://library")!
            self.extensionContext?.open(deepLink, completionHandler: nil)
            self.extensionContext?.completeRequest(
                returningItems: nil,
                completionHandler: nil
            )
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

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

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "Cecilia's Notes"
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabel
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let spinner: UIActivityIndicatorView = {
        let s = UIActivityIndicatorView(style: .medium)
        s.translatesAutoresizingMaskIntoConstraints = false
        s.startAnimating()
        return s
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Visible content matters here. Earlier "silent" attempts
        // (no subviews at all) caused iOS to suspend the extension
        // after 2 minutes without ever firing `completeRequest` —
        // the share sheet hung. A spinner + brand label is the
        // minimum surface the share-extension framework considers
        // "real UI," and the user only sees it for a fraction of a
        // second before the deep link transitions them into the
        // main app.
        view.backgroundColor = .systemBackground
        let stack = UIStackView(arrangedSubviews: [spinner, statusLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await ingestAndComplete() }
    }

    // MARK: - Ingest

    private func ingestAndComplete() async {
        // Save the file to the app-group inbox, then deep-link into
        // the main app. `completeRequest` MUST run inside `open`'s
        // completion handler — calling them back-to-back without
        // the chain caused iOS to suspend the extension before the
        // URL was actually dispatched, leaving the share sheet
        // hung for ~2 minutes before the system reaped it.
        await ingestAttachments()
        await MainActor.run {
            spinner.stopAnimating()
        }
        // Brief settle so iOS has time to flush the view update
        // before the deep-link transition. Without this the
        // extension's view never gets a chance to repaint, which
        // historically broke the open call on some iOS versions.
        try? await Task.sleep(nanoseconds: 250_000_000)
        await MainActor.run {
            let deepLink = URL(string: "ceciliasnotes://library")!
            // `extensionContext?.open(_:)` is unreliable for share
            // extensions on every iOS version we ship to (17.6+) —
            // the call returns success but the host app never
            // actually launches, leaving the user dumped back to
            // the source app's home screen. The reliable workaround
            // is to walk the responder chain until we hit something
            // that handles `openURL:`. The share-host scene exposes
            // a parent UIResponder that dispatches the URL to the
            // system, which DOES launch the target app.
            openHostURL(deepLink)
            // Fire `completeRequest` after a brief delay so the
            // openURL: dispatch lands before the extension is torn
            // down. Calling them back-to-back races the system —
            // the extension exits before iOS has a chance to act
            // on the URL.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.extensionContext?.completeRequest(
                    returningItems: nil,
                    completionHandler: nil
                )
            }
        }
    }

    /// Walks the responder chain looking for a responder that
    /// implements `openURL:`. The share-host scene's parent
    /// responder dispatches the URL through `LSApplicationWorkspace`,
    /// which launches the registered app even from inside a share
    /// extension. Used in place of the unreliable
    /// `extensionContext.open(_:)`.
    @MainActor
    private func openHostURL(_ url: URL) {
        var responder: UIResponder? = self
        let selector = NSSelectorFromString("openURL:")
        while let current = responder {
            if let app = current as? UIApplication {
                app.open(url, options: [:], completionHandler: nil)
                return
            }
            if current.responds(to: selector) {
                _ = current.perform(selector, with: url)
                return
            }
            responder = current.next
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

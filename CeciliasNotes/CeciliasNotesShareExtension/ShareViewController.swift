import UIKit
import UniformTypeIdentifiers

/// Cecilia's Notes share-extension entry point. Accepts PDFs, images,
/// plain text, and URLs from any host app and routes them into the
/// shared app-group `ShareInbox` folder (or `.cnshare` JSON for text).
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
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                await ingestText(provider: provider, typeID: UTType.plainText.identifier, inbox: inboxURL)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                await ingestURL(provider: provider, inbox: inboxURL)
            } else if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) {
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

    private func ingestURL(provider: NSItemProvider, inbox: URL) async {
        let item: NSSecureCoding?
        do {
            item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil)
        } catch {
            return
        }
        let urlString: String?
        if let url = item as? URL {
            urlString = url.absoluteString
        } else if let url = item as? NSURL {
            urlString = url.absoluteString
        } else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
            urlString = s
        } else {
            urlString = nil
        }
        guard let link = urlString?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty else { return }
        let title = URL(string: link)?.host ?? "Link"
        writeCapturePayload(title: title, body: link, inbox: inbox)
    }

    private func ingestText(provider: NSItemProvider, typeID: String, inbox: URL) async {
        let item: NSSecureCoding?
        do {
            item = try await provider.loadItem(forTypeIdentifier: typeID, options: nil)
        } catch {
            return
        }
        let text: String?
        if let s = item as? String {
            text = s
        } else if let data = item as? Data {
            text = String(data: data, encoding: .utf8)
        } else if let attr = item as? NSAttributedString {
            text = attr.string
        } else {
            text = nil
        }
        guard let body = text?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else { return }
        let title = body
            .split(whereSeparator: \.isNewline)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        writeCapturePayload(
            title: title.isEmpty ? "Shared note" : String(title.prefix(80)),
            body: body,
            inbox: inbox
        )
    }

    private func writeCapturePayload(title: String, body: String, inbox: URL) {
        let payload = ["title": title, "body": body]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let file = inbox.appendingPathComponent("\(UUID().uuidString).cnshare")
        try? data.write(to: file, options: .atomic)
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

        // Preserve the original file basename when we have it — the
        // import pipeline reads `url.lastPathComponent` to name the
        // notebook, so writing as `<uuid>.pdf` would strip the user's
        // PDF title. Fall back to the item provider's suggested name,
        // then to a UUID for items that arrived as raw Data without
        // any name attached (rare; mostly Mail / share-as-image).
        let baseName = preservedBaseName(
            from: item,
            provider: provider,
            extension: suggestedExt
        )
        let destination = uniqueDestination(
            in: inbox,
            baseName: baseName,
            ext: suggestedExt
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

    /// Best-effort original basename for the dropped item. URL items
    /// expose the file's name directly; `NSItemProvider.suggestedName`
    /// is also worth checking (some apps set it even when the item
    /// arrives as Data).
    private func preservedBaseName(
        from item: NSSecureCoding?,
        provider: NSItemProvider,
        extension ext: String
    ) -> String {
        if let url = item as? URL {
            let stem = url.deletingPathExtension().lastPathComponent
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !stem.isEmpty { return stem }
        }
        if let suggested = provider.suggestedName?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !suggested.isEmpty {
            // suggestedName may carry its own extension — strip it
            // so we don't end up with "Foo.pdf.pdf" on disk.
            let url = URL(fileURLWithPath: suggested)
            return url.deletingPathExtension().lastPathComponent
        }
        return UUID().uuidString
    }

    /// Avoid clobbering an inbox file with the same name. Walks
    /// `Foo.pdf`, `Foo 2.pdf`, `Foo 3.pdf`, … until a free slot.
    private func uniqueDestination(
        in inbox: URL,
        baseName: String,
        ext: String
    ) -> URL {
        let primary = inbox.appendingPathComponent("\(baseName).\(ext)")
        if !FileManager.default.fileExists(atPath: primary.path) { return primary }
        var n = 2
        while true {
            let candidate = inbox.appendingPathComponent("\(baseName) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
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

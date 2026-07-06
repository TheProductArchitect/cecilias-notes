import AppKit

@MainActor
enum MacCopyPageService {
    static func copyPage(
        _ page: Page,
        notebook: Notebook,
        storage: StorageService,
        scale: CGFloat = 2
    ) {
        Task {
            guard let image = await MacExportService.renderPage(
                page, notebook: notebook, storage: storage, scale: scale
            ) else { return }
            await MainActor.run {
                PlatformClipboard.copyImage(image)
            }
        }
    }
}

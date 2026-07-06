import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Copies the current page raster to the system clipboard (iPad/iPhone).
@MainActor
enum CopyPageService {
    static func copyPage(_ page: Page) {
#if canImport(UIKit)
        guard let image = ExportService.shared.rasterisePageForFallback(page) else { return }
        PlatformClipboard.copyImage(image)
        HapticManager.shared.toolSwitched()
#endif
    }
}

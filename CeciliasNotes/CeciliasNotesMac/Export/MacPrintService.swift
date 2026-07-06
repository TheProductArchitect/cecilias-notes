import AppKit
import PDFKit

@MainActor
enum MacPrintService {
    /// Renders every page in the notebook to a temporary PDF and
    /// presents the system print panel.
    static func printNotebook(_ notebook: Notebook, storage: StorageService) {
        let pages = storage.fetchPages(in: notebook)
        guard !pages.isEmpty else { return }

        Task {
            let pdf = PDFDocument()
            for (index, page) in pages.enumerated() {
                guard let image = await MacExportService.renderPage(
                    page, notebook: notebook, storage: storage, scale: 2
                ),
                let pdfPage = PDFPage(image: image) else { continue }
                pdf.insert(pdfPage, at: index)
            }
            guard pdf.pageCount > 0 else { return }

            await MainActor.run {
                let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
                pdfView.document = pdf
                pdfView.autoScales = true
                let operation = NSPrintOperation(view: pdfView, printInfo: NSPrintInfo.shared)
                operation.showsPrintPanel = true
                operation.run()
            }
        }
    }
}

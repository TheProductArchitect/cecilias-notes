import SwiftData
import XCTest
@testable import CeciliasNotes

/// Duplication fidelity (2026-07-17 audit). Two classes of loss were
/// shipping: `duplicatePage` skipped V6 elements ENTIRELY (only ink +
/// legacy TextBlocks survived a page duplicate), and the shared
/// element clone dropped pdfPage/highlight elements, shape fills +
/// contained text, and image crop rects. These tests pin the full
/// per-kind field fidelity through the page-duplicate path — the
/// notebook-duplicate path runs the same `cloneV6PageElements`.
@MainActor
final class DuplicationFidelityTests: XCTestCase {

    private func elements(pageId: UUID) -> [PageElement] {
        let d = FetchDescriptor<PageElement>(
            predicate: #Predicate<PageElement> { $0.pageId == pageId && $0.deletedAt == nil }
        )
        return (try? StorageService.shared.context.fetch(d)) ?? []
    }

    private func makeNotebookWithPage() throws -> (Notebook, Page) {
        let storage = StorageService.shared
        let nb = try storage.createNotebook(
            title: "Dup fidelity \(UUID().uuidString.prefix(6))",
            subjectId: nil,
            coverColorHex: "#FFFFFF",
            coverTexture: .none,
            pageSize: .a4,
            template: .blank
        )
        guard let page = storage.fetchPages(in: nb).first else {
            throw XCTSkip("Seed page missing")
        }
        return (nb, page)
    }

    func test_duplicatePage_carriesEveryV6ElementKind() throws {
        let (nb, page) = try makeNotebookWithPage()
        let ctx = StorageService.shared.context

        // Text
        let text = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .text,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.5, normalizedHeight: 0.1,
            rotation: 0.3, zIndex: 1, opacity: 0.8, isLocked: true
        )
        text.textContent = TextContent(text: "carry me")
        ctx.insert(text)

        // Shape with fill + contained text (dropped by the old clone)
        let shape = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .shape,
            normalizedX: 0.2, normalizedY: 0.3,
            normalizedWidth: 0.2, normalizedHeight: 0.2, zIndex: 2
        )
        let shapeContent = ShapeContent(
            shapeKind: .rectangle, strokeColorHex: "#112233",
            strokeWidth: 2, strokeStyle: .solid
        )
        shapeContent.fillColorHex = "#AABBCC"
        shapeContent.fillOpacity = 0.5
        shapeContent.containedText = "label"
        shape.shapeContent = shapeContent
        ctx.insert(shape)

        // Cropped image (crop rect was dropped by the old clone)
        let image = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .image,
            normalizedX: 0.4, normalizedY: 0.5,
            normalizedWidth: 0.3, normalizedHeight: 0.2, zIndex: 3
        )
        let imageId = UUID()
        let imageContent = ImageContent(
            id: imageId, filename: "\(imageId.uuidString).jpg",
            fileFormat: "jpg", originalPixelWidth: 100, originalPixelHeight: 100,
            imageData: Data([0xFF, 0xD8, 0xFF])
        )
        imageContent.cropOriginX = 0.1
        imageContent.cropOriginY = 0.2
        imageContent.cropWidth = 0.6
        imageContent.cropHeight = 0.5
        image.imageContent = imageContent
        ctx.insert(image)

        // PDF page + highlight referencing it (skipped entirely by
        // the old clone — a duplicated PDF notebook lost its pages)
        let pdf = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .pdfPage,
            normalizedX: 0, normalizedY: 0,
            normalizedWidth: 1, normalizedHeight: 1, zIndex: 0
        )
        let docId = UUID()
        let pdfContent = PDFPageContent(
            pdfDocumentId: docId, pageIndex: 3,
            originalPageWidth: 595, originalPageHeight: 842
        )
        pdfContent.extractedText = "page text"
        pdf.pdfPageContent = pdfContent
        ctx.insert(pdf)

        let highlight = PageElement(
            pageId: page.id, notebookId: nb.id, kind: .highlight,
            normalizedX: 0.1, normalizedY: 0.1,
            normalizedWidth: 0.2, normalizedHeight: 0.05, zIndex: 4
        )
        let highlightContent = HighlightContent(
            pdfPageContentId: pdfContent.id,
            rectOriginX: 0.1, rectOriginY: 0.1,
            rectWidth: 0.2, rectHeight: 0.05,
            style: .highlight, colorVariant: "yellow"
        )
        highlightContent.capturedText = "quoted"
        highlight.highlightContent = highlightContent
        ctx.insert(highlight)
        try ctx.save()

        let copy = try StorageService.shared.duplicatePage(page)
        let cloned = elements(pageId: copy.id)

        // One clone per kind.
        func clone(_ kind: ElementKind) -> PageElement? {
            cloned.first { $0.kind == kind }
        }
        XCTAssertNotNil(clone(.text), "Text element must survive page duplicate")
        XCTAssertNotNil(clone(.shape), "Shape must survive page duplicate")
        XCTAssertNotNil(clone(.image), "Image must survive page duplicate")
        XCTAssertNotNil(clone(.pdfPage), "PDF page must survive page duplicate")
        XCTAssertNotNil(clone(.highlight), "Highlight must survive page duplicate")

        // Scaffold fidelity.
        let textClone = try XCTUnwrap(clone(.text))
        XCTAssertEqual(textClone.rotation, 0.3, accuracy: 0.0001)
        XCTAssertEqual(textClone.opacity, 0.8, accuracy: 0.0001)
        XCTAssertTrue(textClone.isLocked)
        XCTAssertEqual(textClone.textContent?.text, "carry me")

        // Shape fill + label.
        let shapeClone = try XCTUnwrap(clone(.shape)?.shapeContent)
        XCTAssertEqual(shapeClone.fillColorHex, "#AABBCC")
        XCTAssertEqual(shapeClone.fillOpacity ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(shapeClone.containedText, "label")

        // Image crop.
        let imageClone = try XCTUnwrap(clone(.image)?.imageContent)
        XCTAssertEqual(imageClone.cropOriginX ?? -1, 0.1, accuracy: 0.0001)
        XCTAssertEqual(imageClone.cropWidth ?? -1, 0.6, accuracy: 0.0001)
        XCTAssertNotEqual(imageClone.id, imageId, "Image content id must be fresh")

        // PDF: SAME shared document, FRESH content row.
        let pdfClone = try XCTUnwrap(clone(.pdfPage)?.pdfPageContent)
        XCTAssertEqual(pdfClone.pdfDocumentId, docId, "PDF file is shared by design")
        XCTAssertEqual(pdfClone.pageIndex, 3)
        XCTAssertNotEqual(pdfClone.id, pdfContent.id, "PDFPageContent row must be fresh")

        // Highlight re-links to the CLONED pdf content, not the source.
        let highlightClone = try XCTUnwrap(clone(.highlight)?.highlightContent)
        XCTAssertEqual(highlightClone.pdfPageContentId, pdfClone.id,
                       "Cloned highlight must reference the cloned PDF page")
        XCTAssertEqual(highlightClone.capturedText, "quoted")
    }
}

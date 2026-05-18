/// EditorViewModel+Highlighter.swift
/// Cecilia's Notes
///
/// Stroke interception for the highlighter family on PDF pages.
/// When the user completes a stroke with a highlighter-family tool
/// active AND the stroke passes over selectable PDF text, the
/// editor:
///
///   1. Extracts the text under the stroke via
///      `PDFPage.character(at:)`.
///   2. Creates one or more `PageElement(.highlight) +
///      HighlightContent` rows via `HighlightCommit` (multi-line
///      selections become one PageElement per line, sharing a
///      `groupId`).
///   3. Removes the just-committed PencilKit stroke from the
///      canvas.
///   4. Registers an undo step that restores the stroke and
///      soft-deletes the highlight group.
///
/// Step 5.5 rewired this off `PDFTextAnnotationStore` /
/// `PDFAnnotationWriter` onto the unified V6 element model. The
/// commit path looks up the active PDF page via the V6
/// `PageElement(.pdfPage)` row on the current page rather than the
/// retired `Page.pdfPageIndex` + `Notebook.sourcePDFURL`.
///
/// Strokes over blank space or scanned-image PDFs (no selectable
/// text) fall through unchanged.

import Foundation
import PDFKit
import PencilKit
import SwiftData
import UIKit

extension EditorViewModel {

    // MARK: - Entry point

    func attemptHighlighterTextDetection() {
        guard let style = selectedTool.pdfHighlightStyle else { return }
        guard let canvas = canvasView else { return }
        guard let lastStroke = canvas.drawing.strokes.last else { return }

        // Step 5.5: look up the V6 PDF page element for the
        // current page rather than reading the retired
        // `Notebook.sourcePDFURL` + `Page.pdfPageIndex` pair.
        guard let pdfBacking = currentPagePDFBacking() else { return }
        guard let document = PDFDocument(url: pdfBacking.fileURL),
              let pdfPage = document.page(at: pdfBacking.pageIndex)
        else { return }

        let canvasSamples = sampleStrokePoints(lastStroke, spacing: 10)
        guard canvasSamples.count >= 2 else { return }

        // Canvas → PDF coordinate transform. `PDFPageElementView`
        // renders the PDF inside the element's bounds with
        // aspect-fit, identical to the legacy
        // `PageRenderer.drawPDFPage` math — letterboxed inside
        // the element's normalised rect on the host page.
        let pdfRect = pdfPage.bounds(for: .mediaBox)
        let canvasSize = canvas.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0,
              pdfRect.width > 0, pdfRect.height > 0
        else { return }
        let scale = min(canvasSize.width / pdfRect.width,
                        canvasSize.height / pdfRect.height)
        let offsetX = (canvasSize.width - pdfRect.width * scale) / 2
        let offsetY = (canvasSize.height - pdfRect.height * scale) / 2

        var charIndices: [Int] = []
        for sample in canvasSamples {
            let pdfX = (sample.x - offsetX) / scale
            let pdfY = pdfRect.height - (sample.y - offsetY) / scale
            let point = CGPoint(x: pdfX, y: pdfY)
            let idx = pdfPage.characterIndex(at: point)
            if idx >= 0 { charIndices.append(idx) }
        }
        guard charIndices.count >= 3 else { return }

        let minIdx = charIndices.min() ?? 0
        let maxIdx = charIndices.max() ?? minIdx
        let length = max(1, maxIdx - minIdx + 1)
        guard let selection = pdfPage.selection(
            for: NSRange(location: minIdx, length: length)
        ) else { return }

        let selectedText = (selection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return }

        let pdfBounds = selection.bounds(for: pdfPage)
        guard pdfBounds.width > 0, pdfBounds.height > 0 else { return }

        let normalized = CGRect(
            x: pdfBounds.minX / pdfRect.width,
            y: 1.0 - (pdfBounds.maxY / pdfRect.height),
            width: pdfBounds.width / pdfRect.width,
            height: pdfBounds.height / pdfRect.height
        )

        commitHighlight(
            style: style,
            selectedText: selectedText,
            normalizedBounds: normalized,
            pdfPageContentId: pdfBacking.contentId,
            removingStroke: lastStroke
        )
    }

    // MARK: - V6 commit

    private func commitHighlight(
        style: HighlightStyle,
        selectedText: String,
        normalizedBounds: CGRect,
        pdfPageContentId: UUID,
        removingStroke target: PKStroke
    ) {
        guard let canvas = canvasView else { return }

        let undoManager = canvas.undoManager
        undoManager?.beginUndoGrouping()

        // Strip the just-committed stroke.
        let beforeStrokes = canvas.drawing.strokes
        let afterStrokes = beforeStrokes.filter {
            $0.path.creationDate != target.path.creationDate
        }
        guard afterStrokes.count == beforeStrokes.count - 1 else {
            undoManager?.endUndoGrouping()
            return
        }
        canvas.drawing = PKDrawing(strokes: afterStrokes)

        // Commit the V6 highlight element(s). v1 ships single-
        // rect selections through the highlighter detection;
        // multi-line support is a follow-up that splits
        // `selection.selectionsByLine()` and passes the resulting
        // per-line rects into `HighlightCommit.createHighlights`.
        let createdIds = HighlightCommit.createHighlights(
            rects: [normalizedBounds],
            pdfPageContentId: pdfPageContentId,
            pageId: currentPage.id,
            notebookId: notebook.id,
            style: style,
            colorVariant: "yellow",
            capturedText: selectedText
        )

        undoManager?.registerUndo(withTarget: canvas) { canvasTarget in
            var restored = canvasTarget.drawing.strokes
            restored.append(target)
            restored.sort { $0.path.creationDate < $1.path.creationDate }
            canvasTarget.drawing = PKDrawing(strokes: restored)
            // Soft-delete the highlight rows created above.
            let context = StorageService.shared.context
            for elementId in createdIds {
                let descriptor = FetchDescriptor<PageElement>(
                    predicate: #Predicate { $0.id == elementId }
                )
                if let element = try? context.fetch(descriptor).first {
                    element.deletedAt = Date()
                    element.updatedAt = Date()
                }
            }
            try? context.save()
            NotificationCenter.default.post(
                name: .highlightElementsChanged, object: nil
            )
        }
        switch style {
        case .highlight:     undoManager?.setActionName("Highlight")
        case .underline:     undoManager?.setActionName("Underline")
        case .strikethrough: undoManager?.setActionName("Strikethrough")
        }
        undoManager?.endUndoGrouping()
    }

    /// Look up the V6 PDF page element backing the current page.
    /// Returns `nil` if the page has no `.pdfPage` element
    /// (non-PDF notebook). Prefers the full-bleed Workflow A
    /// element when several exist; Workflow B's resized
    /// references aren't valid highlighter targets.
    private func currentPagePDFBacking() -> (contentId: UUID, fileURL: URL, pageIndex: Int)? {
        let pageId = currentPage.id
        let context = StorageService.shared.context
        let descriptor = FetchDescriptor<PageElement>(
            predicate: #Predicate { $0.pageId == pageId && $0.deletedAt == nil }
        )
        guard let elements = try? context.fetch(descriptor) else { return nil }
        let candidates = elements.filter { $0.kind == .pdfPage }
        let fullBleed = candidates.first {
            $0.zIndex == 0 &&
                $0.normalizedX == 0 && $0.normalizedY == 0 &&
                $0.normalizedWidth == 1 && $0.normalizedHeight == 1
        } ?? candidates.first
        guard let element = fullBleed,
              let content = element.pdfPageContent else { return nil }
        let url = content.pdfFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return (content.id, url, content.pageIndex)
    }

    // MARK: - Stroke sampling

    private func sampleStrokePoints(_ stroke: PKStroke, spacing: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        var accumulated: CGFloat = 0
        var previous: CGPoint?

        stroke.path.forEach { point in
            let location = point.location
            if let prev = previous {
                let dx = location.x - prev.x
                let dy = location.y - prev.y
                accumulated += (dx * dx + dy * dy).squareRoot()
                if accumulated >= spacing {
                    out.append(location)
                    accumulated = 0
                }
            } else {
                out.append(location)
            }
            previous = location
        }
        if let last = previous, out.last != last {
            out.append(last)
        }
        return out
    }
}

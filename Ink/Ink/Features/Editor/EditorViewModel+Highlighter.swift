/// EditorViewModel+Highlighter.swift
/// Cecilia's Notes
///
/// Stroke interception for the highlighter family (highlighter,
/// underline, strikethrough) on PDF-backed pages. When the user
/// completes a stroke with one of those tools active AND the stroke
/// passes over selectable PDF text, the editor:
///
///   1. Extracts the text under the stroke via `PDFPage.character(at:)`.
///   2. Builds a `PDFTextAnnotationRecord` and saves it to
///      `PDFTextAnnotationStore`.
///   3. Removes the just-committed PencilKit stroke from the canvas.
///   4. Schedules a debounced write-back to the source PDF.
///
/// Wrapped in `undoManager.beginUndoGrouping()` /
/// `endUndoGrouping()` so the user can ⌘Z once to restore both the
/// visible stroke and remove the annotation as a single undo step.
///
/// Strokes over blank space or scanned-image PDFs (no selectable
/// text) fall through unchanged — the marker stroke stays as the
/// existing fallback.

import Foundation
import PDFKit
import PencilKit
import UIKit

extension EditorViewModel {

    // MARK: - Entry point

    /// Called from `handleStrokeEnded` whenever the active tool is a
    /// highlighter-family tool. Safe to call on non-PDF notebooks —
    /// returns immediately when there's no PDF backing.
    func attemptHighlighterTextDetection() {
        guard let annotationType = selectedTool.pdfTextAnnotationType else { return }
        guard let canvas = canvasView else { return }
        guard notebook.isPDFBacked else { return }
        guard let writer = pdfAnnotationWriter else { return }
        guard let pdfPageIndex = currentPage.pdfPageIndex else { return }
        guard let pdfPage = writer.document.page(at: pdfPageIndex) else { return }
        guard let lastStroke = canvas.drawing.strokes.last else { return }

        // Sample the stroke path in canvas space. ~10pt spacing is
        // dense enough to land at least one sample per character on
        // typical body text without spamming `character(at:)`.
        let canvasSamples = sampleStrokePoints(lastStroke, spacing: 10)
        guard canvasSamples.count >= 2 else { return }

        // Canvas → PDF coordinate transform. PageRenderer
        // letterboxes the PDF inside the canvas bounds (preserving
        // aspect ratio, centred); reproduce the same math here so
        // hit-tests land where the user sees the text.
        let pdfRect = pdfPage.bounds(for: .mediaBox)
        let canvasSize = canvas.bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0,
              pdfRect.width > 0, pdfRect.height > 0
        else { return }
        let scale = min(canvasSize.width / pdfRect.width,
                        canvasSize.height / pdfRect.height)
        let offsetX = (canvasSize.width - pdfRect.width * scale) / 2
        let offsetY = (canvasSize.height - pdfRect.height * scale) / 2

        // Collect character indices touched by the stroke. PDFKit's
        // `character(at:)` takes a point in PDF page coordinates
        // (origin bottom-left). Negative return values mean "no
        // character at that point" (image / whitespace).
        var charIndices: [Int] = []
        for sample in canvasSamples {
            let pdfX = (sample.x - offsetX) / scale
            // Flip y: PDFKit origin is bottom-left, canvas is top-left.
            let pdfY = pdfRect.height - (sample.y - offsetY) / scale
            let point = CGPoint(x: pdfX, y: pdfY)
            let idx = pdfPage.characterIndex(at: point)
            if idx >= 0 { charIndices.append(idx) }
        }

        // Spec: at least 3 characters under the stroke to count as
        // a text annotation. Below that we leave the marker stroke
        // as the visible fallback — covers the "stroke drifted onto
        // a tiny corner of text" edge case where the user clearly
        // intended a regular highlight.
        guard charIndices.count >= 3 else { return }

        // Build a selection spanning the min..max character index.
        // PDFPage.selection(for:) over a single range returns the
        // tightest text-bound rect set, which is what we want for
        // the underline / strike geometry.
        let minIdx = charIndices.min() ?? 0
        let maxIdx = charIndices.max() ?? minIdx
        let length = max(1, maxIdx - minIdx + 1)
        let selection = pdfPage.selection(
            for: NSRange(location: minIdx, length: length)
        )
        guard let selection else { return }

        let selectedText = (selection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selectedText.isEmpty else { return }

        let pdfBounds = selection.bounds(for: pdfPage)
        guard pdfBounds.width > 0, pdfBounds.height > 0 else { return }

        // Convert the PDF selection bounds back to normalised
        // 0–1 top-left-origin coordinates that match the rest of
        // the side-channel store geometry.
        let normalized = CGRect(
            x: pdfBounds.minX / pdfRect.width,
            y: 1.0 - (pdfBounds.maxY / pdfRect.height),
            width: pdfBounds.width / pdfRect.width,
            height: pdfBounds.height / pdfRect.height
        )

        commitAnnotation(
            type: annotationType,
            selectedText: selectedText,
            normalizedBounds: normalized,
            pdfPageIndex: pdfPageIndex,
            removingStroke: lastStroke
        )
    }

    // MARK: - Commit (record + stroke removal + undo grouping)

    /// Atomic stroke-replace-with-annotation. Undo grouping wraps
    /// both halves so a single ⌘Z restores the stroke and removes
    /// the annotation in one user-visible step.
    private func commitAnnotation(
        type: PDFTextAnnotationType,
        selectedText: String,
        normalizedBounds: CGRect,
        pdfPageIndex: Int,
        removingStroke target: PKStroke
    ) {
        guard let canvas = canvasView,
              let writer = pdfAnnotationWriter
        else { return }

        let pageId = currentPage.id
        let record = PDFTextAnnotationRecord(
            id: UUID(),
            pageId: pageId,
            type: type,
            selectedText: selectedText,
            normalizedBounds: normalizedBounds,
            pdfPageIndex: pdfPageIndex,
            createdAt: Date(),
            updatedAt: Date(),
            deletedAt: nil
        )

        let undoManager = canvas.undoManager
        undoManager?.beginUndoGrouping()

        // Half 1: strip the most-recent stroke. Locate by identity
        // (path.creationDate) rather than index because additional
        // strokes could theoretically have landed between
        // canvasViewDidEndUsingTool and here.
        let beforeStrokes = canvas.drawing.strokes
        let afterStrokes = beforeStrokes.filter {
            $0.path.creationDate != target.path.creationDate
        }
        guard afterStrokes.count == beforeStrokes.count - 1 else {
            // Couldn't find the target stroke — abandon rather than
            // mutating an unknown drawing state.
            undoManager?.endUndoGrouping()
            return
        }
        canvas.drawing = PKDrawing(strokes: afterStrokes)

        // Half 2: persist the record + reflect into the in-memory
        // PDFDocument so re-renders see it. Disk write is debounced.
        PDFTextAnnotationStore.save(record)
        writer.applyToInMemoryDocument(record)
        writer.scheduleWrite()

        // Register the inverse so undo restores the stroke + removes
        // the record + clears the in-memory annotation. Captured by
        // value so a later mutation of `record` (impossible — it's a
        // struct) can't drift.
        let recordId = record.id
        undoManager?.registerUndo(withTarget: canvas) { canvasTarget in
            // Re-insert the original stroke at its original
            // position. Strokes are value types so this is a
            // straightforward concatenation.
            var restored = canvasTarget.drawing.strokes
            restored.append(target)
            canvasTarget.drawing = PKDrawing(strokes: restored)
            PDFTextAnnotationStore.softDelete(id: recordId, pageId: pageId)
            // Mirror the soft-delete into the in-memory document.
            // The writer is captured weakly to avoid retaining the
            // editor session if undo fires after dismiss.
            Task { @MainActor [weak writer] in
                writer?.removeFromInMemoryDocument(
                    recordId: recordId,
                    pdfPageIndex: pdfPageIndex
                )
                writer?.scheduleWrite()
            }
        }
        switch type {
        case .highlight:     undoManager?.setActionName("Highlight")
        case .underline:     undoManager?.setActionName("Underline")
        case .strikethrough: undoManager?.setActionName("Strikethrough")
        }
        undoManager?.endUndoGrouping()
    }

    // MARK: - Stroke sampling

    /// Walks a `PKStroke`'s control points and returns ~one canvas
    /// point per `spacing` pt of arc length. Used to pick character
    /// hit-test targets along the stroke path.
    private func sampleStrokePoints(_ stroke: PKStroke, spacing: CGFloat) -> [CGPoint] {
        var out: [CGPoint] = []
        var accumulated: CGFloat = 0
        var previous: CGPoint?

        stroke.path.forEach { point in
            // The stroke path is in canvas coordinates already.
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
        // Always include the last point so the upper-bound character
        // is captured even when the stroke ends mid-spacing-window.
        if let last = previous, out.last != last {
            out.append(last)
        }
        return out
    }
}

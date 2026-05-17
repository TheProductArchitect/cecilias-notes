/// PDFAnnotationWriter.swift
/// Cecilia's Notes
///
/// Per-notebook-session service that mirrors the in-app
/// `PDFTextAnnotationStore` into the source PDF file as proper
/// `PDFAnnotation` objects. Writes are debounced 3 seconds; the
/// editor also flushes immediately on notebook close / app
/// background to guarantee no data loss.
///
/// Owns nothing in the data layer — the store is the source of
/// truth. The writer's only job is producing a PDF file that
/// external readers (Preview, Adobe Reader, etc.) can open with the
/// annotations visible. Re-runs are idempotent: every
/// `PDFAnnotation` is stamped with the corresponding record's
/// `id.uuidString` in `forAnnotationKey: .contents`, so a second
/// pass over the same record skips instead of duplicating.

import Foundation
import PDFKit
import UIKit

/// Not a singleton — instantiated by the editor when a PDF-backed
/// notebook session begins and torn down when it ends. The instance
/// keeps a reference to the in-memory `PDFDocument` so re-renders by
/// `PageRenderer` see the annotations the moment they're added,
/// independent of the debounced write-back.
@MainActor
final class PDFAnnotationWriter {

    // MARK: - Properties

    private let notebookId: UUID
    private let sourceURL: URL
    /// The shared `PDFDocument` used both for canvas rendering and
    /// for write-back. `PageRenderer` reads pages from the same
    /// document instance, so adding annotations here makes them
    /// visible on the canvas after a `setNeedsDisplay`.
    private(set) var document: PDFDocument

    /// Per-page debounce. Calling `scheduleWrite()` cancels the
    /// pending task and schedules a fresh one 3s out.
    private var pendingWrite: Task<Void, Never>?

    /// Pages that need their `PageRenderer` thumbnail / canvas
    /// invalidated after the next successful write — the writer
    /// posts a notification with this list so the editor can call
    /// `setNeedsDisplay()` on the affected page renderers.
    private var dirtyPageIndices: Set<Int> = []

    // MARK: - Lifecycle

    /// Returns `nil` when the PDF cannot be opened (missing,
    /// corrupted, or not actually a PDF-backed notebook). The editor
    /// uses this signal to skip wiring annotation interception on
    /// non-PDF notebooks.
    init?(notebookId: UUID, sourceURL: URL) {
        guard let doc = PDFDocument(url: sourceURL) else { return nil }
        self.notebookId = notebookId
        self.sourceURL = sourceURL
        self.document = doc
    }

    deinit {
        // Cancel any pending debounce. The editor's explicit flush
        // on background covers the data-loss case; cancelling here
        // just avoids a stale write after the writer is gone.
        pendingWrite?.cancel()
    }

    // MARK: - Public API

    /// Schedule a debounced write of every active text annotation
    /// for this notebook into the source PDF on disk. Calls within
    /// 3s of each other coalesce.
    func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await self?.writeNow()
        }
    }

    /// Flush the write immediately, no debounce. Called from the
    /// editor on notebook close + from the app's background
    /// notification observer so an in-flight session doesn't lose
    /// recent annotations.
    func flushImmediately() async {
        pendingWrite?.cancel()
        pendingWrite = nil
        await writeNow()
    }

    /// Build a `PDFAnnotation` for a record and add it to the
    /// in-memory `PDFDocument` immediately. The editor calls this
    /// when a record is created so the annotation is visible on the
    /// canvas before the debounced disk write fires. Idempotent —
    /// re-adding a record whose annotation already exists is a no-op.
    func applyToInMemoryDocument(_ record: PDFTextAnnotationRecord) {
        guard let pdfPage = document.page(at: record.pdfPageIndex) else { return }
        // Skip if an annotation tagged with this record id already
        // sits on the page — keeps the call idempotent.
        let existingMatch = pdfPage.annotations.contains { ann in
            (ann.value(forAnnotationKey: .contents) as? String) == record.id.uuidString
        }
        guard !existingMatch else { return }
        guard let annotation = Self.makeAnnotation(for: record, on: pdfPage) else { return }
        pdfPage.addAnnotation(annotation)
        dirtyPageIndices.insert(record.pdfPageIndex)
    }

    /// Remove the in-memory annotation tagged with `record.id`, if
    /// any. Mirrors `softDelete` in the store so the canvas overlay
    /// + in-memory PDF stay aligned without a full reload.
    func removeFromInMemoryDocument(recordId: UUID, pdfPageIndex: Int) {
        guard let pdfPage = document.page(at: pdfPageIndex) else { return }
        let key = recordId.uuidString
        let matches = pdfPage.annotations.filter { ann in
            (ann.value(forAnnotationKey: .contents) as? String) == key
        }
        for ann in matches {
            pdfPage.removeAnnotation(ann)
        }
        if !matches.isEmpty {
            dirtyPageIndices.insert(pdfPageIndex)
        }
    }

    // MARK: - Write implementation

    /// Reconcile every active record in `PDFTextAnnotationStore`
    /// with the source PDF on disk. The actual file write is done
    /// off the main actor via `Task.detached` per the architecture
    /// rule that PDF mutations never block the main thread.
    private func writeNow() async {
        // Snapshot what's on disk + what needs to be there.
        let allActive = PDFTextAnnotationStore.allActiveRecords()
        let recordsByPage: [Int: [PDFTextAnnotationRecord]] = Dictionary(
            grouping: allActive,
            by: \.pdfPageIndex
        )

        // Add any missing annotations to the in-memory document so
        // the export path + the cache stay aligned. Removals were
        // already done by `removeFromInMemoryDocument` at delete
        // time; we don't re-walk for those here.
        for (pageIndex, records) in recordsByPage {
            guard let pdfPage = document.page(at: pageIndex) else { continue }
            for record in records {
                let alreadyPresent = pdfPage.annotations.contains { ann in
                    (ann.value(forAnnotationKey: .contents) as? String) == record.id.uuidString
                }
                if !alreadyPresent,
                   let annotation = Self.makeAnnotation(for: record, on: pdfPage) {
                    pdfPage.addAnnotation(annotation)
                    dirtyPageIndices.insert(pageIndex)
                }
            }
        }

        // Snapshot the doc data on the main actor (the document is
        // MainActor-isolated through this class) and hand it to a
        // detached task for the file write — PDF serialisation +
        // disk I/O is exactly the work the architecture rule says
        // must stay off the main actor.
        let data = document.dataRepresentation()
        let destination = sourceURL
        await Task.detached(priority: .utility) {
            guard let data else { return }
            try? data.write(to: destination, options: .atomic)
        }.value

        // Tell the editor which page indices changed so its
        // `PageRenderer` instances can invalidate their cached
        // backing and re-paint with the annotations visible.
        if !dirtyPageIndices.isEmpty {
            let indices = dirtyPageIndices
            dirtyPageIndices.removeAll()
            NotificationCenter.default.post(
                name: .pdfAnnotationsWritten,
                object: nil,
                userInfo: [
                    "notebookId": notebookId,
                    "pdfPageIndices": Array(indices)
                ]
            )
        }
    }

    // MARK: - Annotation construction

    /// Build the PDFKit annotation for a record. The annotation's
    /// `forAnnotationKey: .contents` carries the record id so future
    /// passes can detect "already added" and skip.
    ///
    /// Coordinate transform: `record.normalizedBounds` is in
    /// top-left-origin 0–1 page coordinates (the same space every
    /// other side-channel store uses). PDFKit expects bottom-left
    /// origin in PDF points — we flip y and scale to
    /// `pdfPage.bounds(for: .mediaBox)`.
    static func makeAnnotation(
        for record: PDFTextAnnotationRecord,
        on pdfPage: PDFPage
    ) -> PDFAnnotation? {
        let pageRect = pdfPage.bounds(for: .mediaBox)
        guard pageRect.width > 0, pageRect.height > 0 else { return nil }

        let n = record.normalizedBounds
        // Flip Y: our normalised origin is top-left, PDFKit's is
        // bottom-left. Then scale to PDF points.
        let pdfRect = CGRect(
            x: n.minX * pageRect.width,
            y: (1 - n.maxY) * pageRect.height,
            width: n.width * pageRect.width,
            height: n.height * pageRect.height
        )

        let subtype: PDFAnnotationSubtype
        switch record.type {
        case .highlight:     subtype = .highlight
        case .underline:     subtype = .underline
        case .strikethrough: subtype = .strikeOut
        }

        let annotation = PDFAnnotation(
            bounds: pdfRect,
            forType: subtype,
            withProperties: nil
        )
        // PDF-spec yellow for highlights is standard; underline /
        // strike use the same yellow so the on-canvas overlay and
        // the exported PDF stay visually consistent.
        annotation.color = UIColor.systemYellow
        // Tag with the record id so re-runs are idempotent.
        annotation.setValue(record.id.uuidString, forAnnotationKey: .contents)
        return annotation
    }
}

// MARK: - Change notification

extension Notification.Name {
    /// Posted from `PDFAnnotationWriter.writeNow` after a successful
    /// disk write. `userInfo["pdfPageIndices"]` is a `[Int]` of the
    /// page indices that changed; the editor uses this to call
    /// `setNeedsDisplay()` on the affected `PageRenderer` views.
    static let pdfAnnotationsWritten = Notification.Name("pdfAnnotationsWritten")
}

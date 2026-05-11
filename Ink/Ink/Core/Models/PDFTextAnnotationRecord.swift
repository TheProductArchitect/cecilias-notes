/// PDFTextAnnotationRecord.swift
/// Cecilia's Notes
///
/// Codable wire format for PDF text annotations (highlight, underline,
/// strikethrough) that anchor to selectable text on a PDF-backed page.
/// Sibling of `StickyNoteRecord` — both are JSON-serialised through a
/// UserDefaults side-channel store and never enter SwiftData.

import CoreGraphics
import Foundation

/// One PDF text annotation. The record is the in-app source of truth;
/// the corresponding `PDFAnnotation` inside the source PDF file is
/// generated from this record by `PDFAnnotationWriter` (debounced
/// write-back) and by `ExportService` on share-as-PDF.
struct PDFTextAnnotationRecord: Codable, Identifiable, Sendable, Hashable {
    let id: UUID
    let pageId: UUID

    /// What kind of mark — highlight / underline / strikethrough.
    var type: PDFTextAnnotationType

    /// The text that was annotated, captured at creation time. Used
    /// for the customise panel's annotation list and as a fallback
    /// snippet if the source PDF text ever drifts.
    var selectedText: String

    /// Bounds of the annotated selection in normalised 0–1 page
    /// coordinates (origin top-left, matching the rest of the
    /// codebase's normalised geometry). The PDF writer converts to
    /// PDFKit's bottom-left, points-based space at write time.
    var normalizedBounds: CGRect

    /// Which PDF page inside the source document this record lives
    /// on — pinned to the page identity, not the notebook's page
    /// number, so reordering can't desync it.
    var pdfPageIndex: Int

    let createdAt: Date
    var updatedAt: Date
    /// Soft-delete stamp. `nil` = active. Mirrors every other model.
    var deletedAt: Date?
}

/// The three annotation kinds covered by the text-annotation path.
/// Distinct from sticky notes (`StickyNoteRecord`) and from
/// PencilKit strokes — those flow through their own stores.
enum PDFTextAnnotationType: String, Codable, Sendable, Hashable {
    case highlight
    case underline
    case strikethrough
}

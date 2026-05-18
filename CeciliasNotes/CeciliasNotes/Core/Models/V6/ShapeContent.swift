import Foundation
import SwiftData

enum ShapeKind: String, Codable, CaseIterable {
    case rectangle
    case roundedRectangle
    case ellipse
    case triangle
    case arrow
    case line
}

enum ShapeStrokeStyle: String, Codable, CaseIterable {
    case solid
    case dashed
    case dotted
    case none
}

/// Shape content for a `PageElement` of kind `.shape`. **Ships in
/// the V6 schema for forward-compatibility; no user-facing shape
/// tool, picker, or `ShapeElementView` is built in 1.0.** The empty
/// schema slot means adding shapes later is a feature ship, not a
/// schema migration.
///
/// Optional `containedText` lets a single shape render centered
/// text inside its bounds (the common "rectangle with a label"
/// case). For richer text layouts inside shapes, the post-1.0
/// design models them as parent-child `PageElement` relationships
/// rather than expanding this row.
@Model
final class ShapeContent {

    var id: UUID = UUID()
    @Relationship var element: PageElement?

    var shapeKind: ShapeKind = ShapeKind.rectangle

    // Stroke (outline)
    var strokeColorHex: String          = ""
    var strokeWidth: Double             = 0
    var strokeStyle: ShapeStrokeStyle   = ShapeStrokeStyle.solid

    // Fill
    var fillColorHex: String? = nil
    var fillOpacity: Double   = 1.0

    /// Optional centered label rendered inside the shape's bounds.
    var containedText: String?      = nil
    /// Serialised text style (font size, weight). String for the
    /// same reasons `Notebook.defaultTemplateRaw` is a string —
    /// avoids CoreData transformer trouble.
    var containedTextStyle: String? = nil

    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(
        id: UUID = UUID(),
        shapeKind: ShapeKind = .rectangle,
        strokeColorHex: String = "",
        strokeWidth: Double = 0,
        strokeStyle: ShapeStrokeStyle = .solid,
        fillColorHex: String? = nil,
        fillOpacity: Double = 1.0,
        containedText: String? = nil,
        containedTextStyle: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id                 = id
        self.shapeKind          = shapeKind
        self.strokeColorHex     = strokeColorHex
        self.strokeWidth        = strokeWidth
        self.strokeStyle        = strokeStyle
        self.fillColorHex       = fillColorHex
        self.fillOpacity        = fillOpacity
        self.containedText      = containedText
        self.containedTextStyle = containedTextStyle
        self.createdAt          = createdAt
        self.updatedAt          = updatedAt
    }
}

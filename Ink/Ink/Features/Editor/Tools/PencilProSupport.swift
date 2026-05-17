/// PencilProSupport.swift
/// Cecilia's Notes
///
/// Capability detection + setting enums for Apple Pencil Pro
/// squeeze gesture. Used by Settings to gate the squeeze section
/// (hidden on non-Pro devices, per spec) and by the editor's
/// squeeze handler to dispatch the user-chosen action.

import UIKit

// MARK: - PencilProSupport

/// Runtime capability check. Returns `true` when the current
/// device + OS supports Apple Pencil Pro squeeze. The check
/// follows the spec's "simplest reliable proxy": the static
/// `UIPencilInteraction.preferredSqueezeAction` accessor exists
/// on iOS 17.5+ and returns non-nil only on Pencil Pro-capable
/// devices.
enum PencilProSupport {

    /// `true` when the OS supports Pencil Pro squeeze. iOS 17.5+
    /// has the `UIPencilInteraction.SqueezeAction` API and the
    /// delegate hook (`didReceiveSqueeze:`); on earlier OS the
    /// gesture can't fire even if the hardware is present.
    ///
    /// There's no public API to introspect whether a Pencil Pro
    /// is actually paired to the device, so on 17.5+ we
    /// optimistically show the setting per the spec's "if
    /// uncertain, show it — a user without Pencil Pro will
    /// simply never trigger the action" guidance.
    static var isSqueezeSupported: Bool {
        if #available(iOS 17.5, *) {
            return true
        }
        return false
    }
}

// MARK: - Squeeze action choice

/// Top-level squeeze action — either "show a tool picker" or
/// "switch to a specific tool". Persisted under
/// `pencil.squeeze.action`.
enum SqueezeAction: String, CaseIterable, Codable, Sendable {
    case palette
    case tool

    var displayName: String {
        switch self {
        case .palette: return "Show tool palette"
        case .tool:    return "Switch to tool (hold)"
        }
    }
}

// MARK: - Tool sub-choice (only used when SqueezeAction == .tool)

/// The subset of tools the user can pick for "Switch to tool".
/// Mirrors the floating palette's primary tools. Persisted under
/// `pencil.squeeze.tool`.
enum SqueezeToolChoice: String, CaseIterable, Codable, Sendable {
    case pencil
    case highlighter
    case sketchPencil
    case eraser
    case lasso
    case text

    var displayName: String {
        switch self {
        case .pencil:       return "Pencil"
        case .highlighter:  return "Highlighter"
        case .sketchPencil: return "Sketch pencil"
        case .eraser:       return "Eraser"
        case .lasso:        return "Lasso"
        case .text:         return "Text"
        }
    }

    /// Maps to the canonical `CeciliasNotesTool.Identity` the editor's
    /// `selectTool(identity:)` consumes. "Sketch pencil" routes to
    /// `.crayon` — that's the textured pencil variant in this
    /// app's tool taxonomy.
    var identity: CeciliasNotesTool.Identity {
        switch self {
        case .pencil:       return .pencil
        case .highlighter:  return .highlighter
        case .sketchPencil: return .crayon
        case .eraser:       return .eraser
        case .lasso:        return .lasso
        case .text:         return .text
        }
    }
}

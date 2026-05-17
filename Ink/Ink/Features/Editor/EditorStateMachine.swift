import Combine
import Foundation
import SwiftUI

/// Single owner of the editor's high-level *mode* — the orthogonal
/// axis to `EditorViewModel.selectedTool`. Phase 5E pragmatic
/// scope (the saved memory captures why we kept it narrower than
/// the original spec): tool **identity + settings** still live on
/// `InkTool` because every reader in the codebase pulls per-tool
/// colour / width / opacity / eraser-mode from there; replacing
/// them with a flat enum would force ~500 lines of indirection
/// across the tool palette, color picker, width slider, eraser
/// popover, and ruler chrome.
///
/// What this type centralises:
///   • The mode enum — replaces the scattered `activeLectureRecorder`,
///     `activeMediaSource`, `isRecordingPanelVisible`, image
///     selection state, etc.
///   • Mode-transition rules (e.g. can't start audio recording
///     during a lecture).
///   • `canvasIsInteractive` — the single derived signal the canvas
///     consults to decide whether to take Pencil input. Previously
///     read straight off `selectedTool.isDrawingTool`, which missed
///     the "in a non-drawing mode" cases.
///
/// **Mirror strategy:** existing call sites still mutate
/// `viewModel.activeLectureRecorder` / `activeMediaSource` /
/// `recordingState` directly. `EditorViewModel`'s `didSet` hooks on
/// those properties forward the transition into this state machine
/// so the mode stays in sync without touching every call site. New
/// code paths should go through `enterMode(_:)` / `exitMode()`
/// directly.
@MainActor
final class EditorStateMachine: ObservableObject {

    // MARK: - Mode

    /// Mutually-exclusive high-level mode the editor is in. The
    /// default `.drawing` covers ink + every non-drawing tool's
    /// idle state (text/image/sticky/ruler/lasso/eraser); the
    /// non-`.drawing` cases are entered explicitly when a
    /// long-form interaction is in flight.
    enum Mode: Equatable {
        case drawing
        case lectureRecording(sessionId: UUID)
        case audioRecording(sessionId: UUID)
        case textEditing(blockId: UUID)
        case imageSelected(recordId: UUID)
        case stickyNoteEditing(noteId: UUID)

        /// True for `.drawing` only. Used by `canvasIsInteractive`
        /// to gate Pencil input — every non-drawing mode owns the
        /// canvas's input surface (recording panel covers it,
        /// text/sticky/image overlays take taps, etc.).
        var isDrawing: Bool {
            if case .drawing = self { return true }
            return false
        }

        /// Cases that block starting another long-form session.
        /// Used by `enterMode` to reject illegal transitions
        /// (e.g. audio-record during a lecture).
        var blocksRecordingStart: Bool {
            switch self {
            case .lectureRecording, .audioRecording: return true
            default: return false
            }
        }
    }

    // MARK: - Published

    @Published private(set) var mode: Mode = .drawing

    /// Most-recently-active tool identity before the user picked a
    /// non-drawing tool — used by the Pencil-squeeze "restore last
    /// tool" path. Mirrors what `EditorViewModel.lastTool` already
    /// tracks; kept here so the squeeze logic has one place to read
    /// from when the squeeze handler eventually migrates fully.
    @Published private(set) var previousToolIdentity: InkTool.Identity = .pen

    // MARK: - Lifecycle

    init() {}

    // MARK: - Mode transitions

    /// Enter a new mode. Rejects illegal transitions silently —
    /// callers fire-and-forget; the published `mode` reflects the
    /// post-transition state and observers can re-check if needed.
    func enterMode(_ next: Mode) {
        // Idempotent.
        guard mode != next else { return }

        // Rule: lecture and quick-audio recordings are mutually
        // exclusive. Starting one while the other is live is a
        // no-op. The caller's UI surface should already prevent
        // this; the rejection here is a belt-and-braces fallback.
        switch (mode, next) {
        case (.lectureRecording, .audioRecording),
             (.audioRecording, .lectureRecording):
            #if DEBUG
            print("[StateMachine] rejected transition \(mode) → \(next)")
            #endif
            return
        default:
            break
        }

        #if DEBUG
        print("[StateMachine] \(mode) → \(next)")
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
        print("[StateMachine-diag] entering mode \(next), thread=\(Thread.current), isMain=\(Thread.isMainThread)")
        print("[StateMachine-diag]   call stack:\n  \(stack)")
        #endif
        mode = next
    }

    /// Drop back to `.drawing`. Idempotent. Always succeeds.
    func exitMode() {
        guard mode != .drawing else { return }
        #if DEBUG
        print("[StateMachine] \(mode) → .drawing")
        let stack = Thread.callStackSymbols.prefix(8).joined(separator: "\n  ")
        print("[StateMachine-diag] exitMode (was \(mode)), thread=\(Thread.current), isMain=\(Thread.isMainThread)")
        print("[StateMachine-diag]   call stack:\n  \(stack)")
        #endif
        mode = .drawing
    }

    /// Snapshot the outgoing tool identity. Called by
    /// `EditorViewModel.selectTool` before it overwrites
    /// `selectedTool`. The squeeze-restore path reads
    /// `previousToolIdentity` to bounce back.
    func notePreviousTool(_ identity: InkTool.Identity) {
        previousToolIdentity = identity
    }

    // MARK: - Derived

    /// Whether the PencilKit canvas should accept input right now.
    /// Combines two signals:
    ///   • The currently-selected tool is a drawing tool (pen,
    ///     pencil, brush, marker, highlighter, eraser, lasso,
    ///     ruler). Text/sticky/image tools are "non-drawing" — the
    ///     canvas yields to their overlays.
    ///   • The current mode is `.drawing`. A lecture / audio
    ///     recording session, an active text-block edit, or an
    ///     image-selection chrome all suppress canvas input even
    ///     when a drawing tool is selected.
    ///
    /// The canvas coordinator passes the tool-side signal in
    /// because `EditorStateMachine` deliberately doesn't store the
    /// `InkTool` itself — see the type-level doc.
    func canvasIsInteractive(toolIsDrawing: Bool) -> Bool {
        toolIsDrawing && mode.isDrawing
    }
}

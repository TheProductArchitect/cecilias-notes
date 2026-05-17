import SwiftUI
import UIKit

// MARK: - PencilSqueezeDetector

/// Bridges Apple Pencil Pro's squeeze gesture into SwiftUI.
///
/// Uses `UIPencilInteraction`'s squeeze callback (iOS 17.5+ on Pencil Pro
/// hardware). On earlier OS versions or non-Pro Pencils the interaction
/// silently never fires its squeeze handler — the view simply does
/// nothing. Per spec: never tell the user "your pencil doesn't support
/// this"; just don't react.
///
/// Wired to the editor's main ZStack via `.background(...)`. Pass a
/// callback that opens the radial tool wheel.
struct PencilSqueezeDetector: UIViewRepresentable {
    /// Fires once per squeeze when the user releases. Used by the
    /// `.palette` action to toggle the tool wheel open/closed.
    let onSqueezeReleased: () -> Void
    /// Fires when the squeeze begins (finger contact on the squeeze
    /// sensor). Used by the `.tool` action to switch to the chosen
    /// tool while the squeeze is held. Optional — `.palette` action
    /// callers can pass `nil`.
    let onSqueezeBegan: (() -> Void)?
    /// Pairs with `onSqueezeBegan`. Fires when the squeeze ends or
    /// is cancelled — the `.tool` action restores the previous tool.
    let onSqueezeEndedOrCancelled: (() -> Void)?

    init(
        onSqueezeReleased: @escaping () -> Void,
        onSqueezeBegan: (() -> Void)? = nil,
        onSqueezeEndedOrCancelled: (() -> Void)? = nil
    ) {
        self.onSqueezeReleased         = onSqueezeReleased
        self.onSqueezeBegan            = onSqueezeBegan
        self.onSqueezeEndedOrCancelled = onSqueezeEndedOrCancelled
    }

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughHostView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        v.addInteraction(interaction)
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onSqueezeReleased         = onSqueezeReleased
        context.coordinator.onSqueezeBegan            = onSqueezeBegan
        context.coordinator.onSqueezeEndedOrCancelled = onSqueezeEndedOrCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSqueezeReleased: onSqueezeReleased,
            onSqueezeBegan: onSqueezeBegan,
            onSqueezeEndedOrCancelled: onSqueezeEndedOrCancelled
        )
    }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onSqueezeReleased:         () -> Void
        var onSqueezeBegan:            (() -> Void)?
        var onSqueezeEndedOrCancelled: (() -> Void)?

        init(
            onSqueezeReleased: @escaping () -> Void,
            onSqueezeBegan: (() -> Void)?,
            onSqueezeEndedOrCancelled: (() -> Void)?
        ) {
            self.onSqueezeReleased         = onSqueezeReleased
            self.onSqueezeBegan            = onSqueezeBegan
            self.onSqueezeEndedOrCancelled = onSqueezeEndedOrCancelled
        }

        // iOS 17.5+ Pencil Pro squeeze. Phases:
        //   .began  → user pressed the squeeze sensor; fire began callback
        //             so the `.tool` press-and-hold path can switch tools.
        //   .ended  → user released; fire BOTH ended (restore previous tool)
        //             AND released (toggle palette). Call sites pick which.
        //   .cancelled → fire ended (restore tool); skip released.
        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            switch squeeze.phase {
            case .began:
                onSqueezeBegan?()
            case .ended:
                onSqueezeEndedOrCancelled?()
                onSqueezeReleased()
            case .cancelled:
                onSqueezeEndedOrCancelled?()
            @unknown default:
                break
            }
        }
    }
}

// MARK: - PassthroughHostView

/// A UIView that never claims hits. The pencil interaction operates on
/// system pencil events directly; the canvas underneath should still
/// receive every touch.
private final class PassthroughHostView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        nil
    }
}

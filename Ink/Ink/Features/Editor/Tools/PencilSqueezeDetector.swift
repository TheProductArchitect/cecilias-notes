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
    let onSqueeze: () -> Void

    func makeUIView(context: Context) -> UIView {
        let v = PassthroughHostView()
        let interaction = UIPencilInteraction()
        interaction.delegate = context.coordinator
        v.addInteraction(interaction)
        return v
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onSqueeze = onSqueeze
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSqueeze: onSqueeze) }

    final class Coordinator: NSObject, UIPencilInteractionDelegate {
        var onSqueeze: () -> Void
        init(onSqueeze: @escaping () -> Void) { self.onSqueeze = onSqueeze }

        // iOS 17.5+ Pencil Pro squeeze. The phase fires .began then .ended;
        // we only want one trigger per squeeze — treat .ended as the commit.
        @available(iOS 17.5, *)
        func pencilInteraction(
            _ interaction: UIPencilInteraction,
            didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze
        ) {
            if squeeze.phase == .ended { onSqueeze() }
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

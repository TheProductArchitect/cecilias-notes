import SwiftUI

/// Floating "Customise" pill that surfaces in the top-right of the editor
/// for ~5 seconds after a notebook is freshly created. Tapping the pill
/// opens the slide-down `CustomisePanel`. The right-edge "X" dismisses
/// the pill without opening the panel.
///
/// Animation:
///   • Appear: ultra-thin material fades in, with a single subtle pulse
///     (1.0 → 1.05 → 1.0 over 600ms) to draw the eye. Pulse is skipped
///     when Reduce Motion is on.
///   • Auto-dismiss: 5s after first appearance, the pill fades out via
///     `CeciliasNotesSpring.fade`. Owned here so the view is the single source of
///     truth for the timing.
struct CustomisePill: View {
    let onTap: () -> Void
    let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulseScale: CGFloat = 1.0
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: CeciliasNotes.Spacing.xs) {
            // Accent dot + sparkle icon — accent dot lives behind the icon
            // for a touch of colour without taking space.
            ZStack {
                Circle()
                    .fill(Color.inkAccentPrimary.opacity(0.18))
                    .frame(width: 22, height: 22)
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.inkAccentPrimary)
            }

            Button {
                onTap()
            } label: {
                Text("Customise")
                    .font(.inkSubhead)
                    .foregroundColor(.inkTextPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.inkPressable)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.inkTextTertiary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.inkPressable)
            .accessibilityLabel("Dismiss customise pill")
        }
        .padding(.leading, CeciliasNotes.Spacing.sm)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(
                    Capsule()
                        .strokeBorder(Color.inkBorderSubtle, lineWidth: 0.5)
                )
        )
        .scaleEffect(pulseScale)
        .onAppear {
            scheduleAutoDismiss()
            guard !reduceMotion else { return }
            // One-shot pulse: 1.0 → 1.05 → 1.0 over 600ms
            withAnimation(.easeInOut(duration: 0.30)) { pulseScale = 1.05 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                withAnimation(.easeInOut(duration: 0.30)) { pulseScale = 1.0 }
            }
        }
        .onDisappear {
            dismissTask?.cancel()
            dismissTask = nil
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Customise notebook")
        .accessibilityHint("Open the customise panel for this notebook")
    }

    private func scheduleAutoDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.inkSpring(CeciliasNotesSpring.fade)) {
                onDismiss()
            }
        }
    }
}

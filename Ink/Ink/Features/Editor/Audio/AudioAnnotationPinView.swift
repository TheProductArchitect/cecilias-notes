import SwiftUI

// MARK: - AudioAnnotationPinView

/// 32pt circle pin that marks an audio annotation on the page.
/// Idle: inkAccent fill with waveform icon.
/// Playing: pulsing accent ring around the circle.
struct AudioAnnotationPinView: View {

    let annotation:    AudioAnnotation
    let isPlaying:     Bool
    let onLongPress:   () -> Void
    @ObservedObject var viewModel: EditorViewModel

    private let size: CGFloat = 32

    @State private var pulseScale:     CGFloat = 1.0
    @State private var pulseOpacity:   Double  = 0.6
    @State private var isShowingPlayer = false

    var body: some View {
        ZStack {
            // Pulse ring — visible only during playback
            if isPlaying {
                Circle()
                    .stroke(Color.inkAccentPrimary, lineWidth: 2)
                    .frame(width: size + 12, height: size + 12)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)
            }

            // Main circle (the popover anchor)
            Circle()
                .fill(Color.inkAccentPrimary)
                .frame(width: size, height: size)
                .overlay(
                    Image(systemName: isPlaying ? "waveform.and.mic" : "waveform")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                )
        }
        .contentShape(Circle().size(CGSize(width: size + 16, height: size + 16)))
        .onTapGesture { isShowingPlayer = true }
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
        // Per-pin popover. iPad presents this as a real floating popover with an
        // arrow anchored to the pin's centre; `presentationCompactAdaptation(.popover)`
        // forbids the system from collapsing it to a sheet on smaller layouts.
        .popover(
            isPresented: $isShowingPlayer,
            attachmentAnchor: .point(.center),
            arrowEdge: .leading
        ) {
            AudioPlayerView(annotation: annotation, viewModel: viewModel)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.audioLabel(
            duration: annotation.durationSeconds,
            hasTranscription: annotation.isTranscribed
        ))
        .accessibilityHint(A11y.audioHint)
        .accessibilityAddTraits(.isButton)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                startPulse()
            } else {
                pulseScale   = 1.0
                pulseOpacity = 0.6
            }
        }
        .onAppear { if isPlaying { startPulse() } }
    }

    private func startPulse() {
        // Skip the pulse entirely under Reduce Motion.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        withAnimation(
            .easeInOut(duration: 0.7)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale   = 1.6
            pulseOpacity = 0
        }
    }
}

import SwiftUI

// MARK: - AudioAnnotationPinView

/// 32pt circle pin that marks an audio annotation on the page.
/// Idle: inkAccent fill with waveform icon.
/// Playing: pulsing accent ring around the circle.
struct AudioAnnotationPinView: View {

    let annotation:   AudioAnnotation
    let isPlaying:    Bool
    let onTap:        () -> Void
    let onLongPress:  () -> Void

    private let size: CGFloat = 32

    @State private var pulseScale:   CGFloat = 1.0
    @State private var pulseOpacity: Double  = 0.6

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

            // Main circle
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
        .onTapGesture { onTap() }
        .onLongPressGesture(minimumDuration: 0.4) { onLongPress() }
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
        withAnimation(
            .easeOut(duration: 1.2)
            .repeatForever(autoreverses: false)
        ) {
            pulseScale   = 1.6
            pulseOpacity = 0
        }
    }
}

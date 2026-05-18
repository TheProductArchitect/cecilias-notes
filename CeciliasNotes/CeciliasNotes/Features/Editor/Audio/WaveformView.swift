import SwiftUI

// MARK: - WaveformView

/// Renders an audio waveform using SwiftUI Canvas.
///
/// Live mode: bars are appended left-to-right and shift right as new levels arrive.
/// Static mode: pre-computed amplitude array from `AudioRecord.amplitudes`.
/// Playhead: vertical accent line; bars left = accent, bars right = tertiary.
struct WaveformView: View {

    @Environment(\.theme) private var theme

    enum Mode {
        case live(levels: [Float])
        case `static`(amplitudes: [Float], playhead: Double)   // playhead: 0…1
    }

    let mode:       Mode
    var barWidth:   CGFloat = 2.5
    var barSpacing: CGFloat = 1.5
    var minHeight:  CGFloat = 4
    var maxHeight:  CGFloat = 60

    var body: some View {
        TimelineView(.animation(minimumInterval: mode.isLive ? 0.05 : .infinity)) { _ in
            Canvas { ctx, size in
                draw(ctx: ctx, size: size)
            }
        }
    }

    // MARK: - Drawing

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let amplitudes: [Float]
        let playheadX:  CGFloat?

        switch mode {
        case .live(let levels):
            amplitudes = levels
            playheadX  = nil
        case .static(let amps, let t):
            amplitudes = amps
            let barStep = barWidth + barSpacing
            let total   = Int(size.width / barStep)
            playheadX   = CGFloat(t) * CGFloat(total) * barStep
        }

        let barStep    = barWidth + barSpacing
        let totalBars  = Int(size.width / barStep)
        let midY       = size.height / 2

        // Use the last `totalBars` levels so waveform scrolls
        let slice: [Float]
        if amplitudes.count > totalBars {
            slice = Array(amplitudes.suffix(totalBars))
        } else {
            slice = amplitudes
        }

        for (i, amp) in slice.enumerated() {
            let x       = CGFloat(i) * barStep + barWidth / 2
            let barH    = barHeight(for: amp)
            let rect    = CGRect(
                x:      x - barWidth / 2,
                y:      midY - barH / 2,
                width:  barWidth,
                height: barH
            )
            let color: Color
            if let px = playheadX {
                color = x <= px ? theme.accent : theme.foregroundSubtle
            } else {
                color = theme.accent
            }
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 2),
                with: .color(color)
            )
        }

        // Playhead line
        if let px = playheadX {
            let path = Path { p in
                p.move(to:    CGPoint(x: px, y: 0))
                p.addLine(to: CGPoint(x: px, y: size.height))
            }
            ctx.stroke(path, with: .color(theme.accent), lineWidth: 1.5)
        }
    }

    // MARK: - Height mapping (logarithmic scale)

    private func barHeight(for amplitude: Float) -> CGFloat {
        guard amplitude > 0 else { return minHeight }
        let log    = log10(Double(amplitude) * 9 + 1)   // maps 0…1 → 0…1 on log scale
        let scaled = CGFloat(log) * (maxHeight - minHeight) + minHeight
        return max(minHeight, min(maxHeight, scaled))
    }
}

// MARK: - Helpers

private extension WaveformView.Mode {
    var isLive: Bool {
        if case .live = self { return true }
        return false
    }
}

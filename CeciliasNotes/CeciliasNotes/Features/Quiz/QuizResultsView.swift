import SwiftUI

/// Full-screen results shown after the final question. Score, a
/// characterful line, per-type breakdown, the missed list, and two
/// actions.
struct QuizResultsView: View {
    let result: QuizResult
    let onReviewMissed: () -> Void
    let onDone: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                score
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 48)

                Text(result.characterLine)
                    .font(.system(size: 17).italic())
                    .foregroundStyle(theme.foregroundSubtle)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 8)

                divider.padding(.vertical, 28)

                breakdown

                if !result.missed.isEmpty {
                    divider.padding(.vertical, 28)
                    missedSection
                }

                buttons.padding(.top, 36)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(theme.surface)
    }

    private var score: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text("\(result.correct)")
                .font(.system(size: 64, weight: .heavy))
                .foregroundStyle(theme.foreground)
            Text("/\(result.total)")
                .font(.system(size: 20))
                .foregroundStyle(theme.foregroundSubtle)
        }
    }

    private var breakdown: some View {
        VStack(spacing: 12) {
            ForEach(result.orderedTypeBreakdown, id: \.type) { row in
                HStack {
                    Text(row.type.displayName)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.recessivePrimary)
                    Spacer()
                    let pct = row.total == 0 ? 0 : Int((Double(row.correct) / Double(row.total) * 100).rounded())
                    Text("\(row.correct)/\(row.total) · \(pct)%")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.foreground)
                }
            }
        }
    }

    private var missedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("missed")
                .font(.system(size: 8))
                .tracking(0.08)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
            ForEach(Array(result.missed.enumerated()), id: \.offset) { _, q in
                Text("· \(q)")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foregroundMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            if !result.missed.isEmpty {
                Button(action: onReviewMissed) {
                    Text("review missed")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(theme.foreground)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(theme.recessiveQuinary, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Button(action: onDone) {
                Text("done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(theme.accent)
                    )
            }
            .buttonStyle(.plain)
        }
    }

    private var divider: some View {
        Rectangle().fill(theme.recessiveQuinary).frame(height: 0.5)
    }
}

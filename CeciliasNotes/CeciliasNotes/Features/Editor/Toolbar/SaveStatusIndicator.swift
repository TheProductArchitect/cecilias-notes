import SwiftUI

/// Top-right of the editor toolbar. Visualises `SaveStatus`.
///   .idle     → invisible
///   .saving   → cloud SF Symbol fades in
///   .saved    → checkmark.circle for ~1s, then idle
///   .error    → exclamationmark.icloud (persists until next successful save)
struct SaveStatusIndicator: View {
    let status: SaveStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                Color.clear.frame(width: 18, height: 18)
            case .saving:
                Image(systemName: "icloud.and.arrow.up")
                    .foregroundColor(.inkTextTertiary)
                    .transition(.opacity)
            case .saved:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.inkAccentPrimary)
                    .transition(.opacity)
            case .error:
                Image(systemName: "exclamationmark.icloud.fill")
                    .foregroundColor(.inkDestructive)
                    .transition(.opacity)
            }
        }
        .font(.system(size: 14, weight: .medium))
        .frame(width: 22, height: 22)
        .ceciliasNotesAnimation(CeciliasNotesSpring.smooth, value: indicatorKey)
    }

    /// A simple key for animation comparison — we don't want to animate
    /// between two `.error("a")` and `.error("b")` cases.
    private var indicatorKey: String {
        switch status {
        case .idle:    return "idle"
        case .saving:  return "saving"
        case .saved:   return "saved"
        case .error:   return "error"
        }
    }
}

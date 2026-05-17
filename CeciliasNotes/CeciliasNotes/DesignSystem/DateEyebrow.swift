import SwiftUI

/// Tracked-uppercase date eyebrow rendered above the wordmark on the
/// splash and home masthead. Format: `SATURDAY, 9 MAY`.
///
/// Sized at 8pt with 0.08em tracking (`.tracking(0.08)`). Underlying
/// string is the locale's day + ordinal date in the `EEEE, d MMMM`
/// pattern; the `.uppercase` text-case is applied at render time.
struct DateEyebrow: View {
    var date: Date = Date()

    private var formatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, d MMMM"
        return formatter.string(from: date)
    }

    var body: some View {
        Text(formatted)
            .font(.system(size: 8, weight: .regular))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(Color.inkRecessiveTertiary)
            .accessibilityLabel(
                DateFormatter.localizedString(
                    from: date,
                    dateStyle: .full,
                    timeStyle: .none
                )
            )
    }
}

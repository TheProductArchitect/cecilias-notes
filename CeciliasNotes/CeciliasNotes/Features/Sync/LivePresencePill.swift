import SwiftUI

/// A small green "Live" pill that shows which paired devices are
/// currently connected on the local network. Presence only — the
/// pill doesn't distinguish same-account (syncs live via CloudKit)
/// from cross-account (offered a "Send to Device" share); both count
/// as "live". Hidden when nothing is connected.
///
/// Observes BOTH multipeer lanes (`MultipeerSyncService` advertises,
/// `MultipeerSendService` browses) so a peer connected on either lane
/// lights up.
struct LivePresencePill: View {
    @ObservedObject private var receiver = MultipeerSyncService.shared
    @ObservedObject private var sender = MultipeerSendService.shared
    @Environment(\.theme) private var theme

    /// Paired peers connected on either lane, de-duplicated.
    private var liveNames: [String] {
        var names = Set<String>()
        for n in receiver.connectedPeerNames where MultipeerPairingStore.sharedKey(forPeerName: n) != nil {
            names.insert(n)
        }
        for n in sender.connectedPeerNames where MultipeerPairingStore.sharedKey(forPeerName: n) != nil {
            names.insert(n)
        }
        return names.sorted()
    }

    var body: some View {
        let names = liveNames
        if !names.isEmpty {
            HStack(spacing: 6) {
                // Self-contained pulse. The previous `@State` +
                // `.scaleEffect` + `.animation(.repeatForever, value:)`
                // let the forever-running animation capture the dot's
                // LAYOUT geometry when the enclosing settings list
                // re-laid-out (scroll / the `if isEnabled` reveal), so
                // the dot appeared to fly/float across the row.
                // `PhaseAnimator` keeps the animation local to the
                // scale transform — it can't leak into position — and a
                // fixed `frame` reserves the max size so layout never
                // shifts.
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .phaseAnimator([0.9, 1.15]) { dot, scale in
                        dot.scaleEffect(scale)
                    } animation: { _ in .easeInOut(duration: 0.9) }
                    .frame(width: 9, height: 9)
                Text(label(for: names))
                    // Single line, sized to content — device names can
                    // be long, and the toolbar column is narrow; without
                    // this the label wrapped character-by-character into
                    // a tall vertical capsule.
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
            .fixedSize()
            .help(names.joined(separator: ", "))
            .accessibilityLabel("Live: \(names.joined(separator: ", "))")
        }
    }

    /// Compact label — no device names in the pill itself (they can be
    /// long and clutter the toolbar); the full list is in the tooltip /
    /// accessibility label. Just "Live" for one, "Live · N" for more.
    private func label(for names: [String]) -> String {
        names.count == 1 ? "Live" : "Live · \(names.count)"
    }
}

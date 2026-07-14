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

    @State private var pulsing = false

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
            HStack(spacing: 7) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .scaleEffect(pulsing ? 1.15 : 0.9)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                Text(label(for: names))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.foreground)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .overlay(Capsule().strokeBorder(Color.green.opacity(0.35), lineWidth: 1))
            .accessibilityLabel("Live: \(names.joined(separator: ", "))")
            .onAppear { pulsing = true }
        }
    }

    private func label(for names: [String]) -> String {
        switch names.count {
        case 1:  return "Live · \(names[0])"
        default: return "Live · \(names.count) devices"
        }
    }
}

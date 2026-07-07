import SwiftUI

/// Mac Settings → iCloud → pair with iPad/iPhone on the local network.
struct MacMultipeerPairingSection: View {
    @ObservedObject private var sender = MultipeerSendService.shared
    @ObservedObject private var multipeer = MultipeerSyncService.shared
    @Environment(\.theme) private var theme

    @State private var pairingCode = ""

    var body: some View {
        Group {
            if !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            TextField("6-digit code from iPad", text: $pairingCode)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: 180)

            Button("Find Devices") {
                sender.pairWithSelectedOrFirst(code: pairingCode)
            }
            .disabled(pairingCode.count != 6)

            if !sender.discoveredDevices.isEmpty {
                Picker("Nearby", selection: deviceBinding) {
                    ForEach(sender.discoveredDevices) { device in
                        Text(device.label).tag(Optional(device.id))
                    }
                }
            }

            if !allPairedNames.isEmpty {
                ForEach(allPairedNames, id: \.self) { name in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Label(name, systemImage: isLive(name) ? "circle.fill" : "circle")
                                .foregroundStyle(isLive(name) ? theme.accent : theme.foregroundSubtle)
                            Spacer()
                            Button("Forget", role: .destructive) {
                                multipeer.forgetPeer(name)
                                MultipeerPairingStore.forget(peerName: name)
                            }
                        }
                        if let caption = householdCaption(for: name) {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(theme.foregroundSubtle)
                        }
                    }
                }
            }
        }
    }

    private var deviceBinding: Binding<String?> {
        Binding(
            get: { sender.selectedDeviceID },
            set: { id in
                sender.selectedDeviceID = id
                guard let id,
                      let device = sender.discoveredDevices.first(where: { $0.id == id })
                else { return }
                if isSameHousehold(device) {
                    sender.pairFirstParty(with: device.peer)
                }
            }
        )
    }

    private var allPairedNames: [String] {
        Array(Set(multipeer.pairedPeerNames + MultipeerPairingStore.pairedPeerNames())).sorted()
    }

    private var statusMessage: String {
        switch sender.status {
        case .idle: return ""
        case .browsing: return "Searching on your network…"
        case .connecting(let name): return "Connecting to \(name)…"
        case .paired(let name): return "Paired with \(name)"
        case .error(let message): return message
        }
    }

    private var statusColor: Color {
        switch sender.status {
        case .paired: return theme.accent
        case .error: return theme.danger
        default: return theme.foregroundSubtle
        }
    }

    private func isSameHousehold(_ device: MultipeerSendService.DiscoveredDevice) -> Bool {
        guard let remote = device.householdHash,
              let local = MultipeerPairingStore.householdTokenHash()
        else { return false }
        return remote == local
    }

    private func isLive(_ name: String) -> Bool {
        sender.isPeerConnected(name) || multipeer.isPeerConnected(name)
    }

    private func householdCaption(for name: String) -> String? {
        switch MultipeerNotebookShare.isSameHousehold(peerName: name) {
        case .some(true):
            return "Same Apple Account — notebooks sync automatically via iCloud."
        case .some(false):
            return "Different Apple Account — notebooks won't sync. Right-click a notebook → Send to Device to share it."
        case .none:
            return nil
        }
    }
}

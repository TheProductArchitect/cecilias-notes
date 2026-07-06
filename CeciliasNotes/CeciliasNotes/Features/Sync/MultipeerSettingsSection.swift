import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Settings → Cloud — multipeer receive toggle, pairing code, and
/// paired-device trust management. Shared by iPad/iPhone Cloud settings
/// and the Mac iCloud settings tab.
struct MultipeerSettingsSection: View {
    @ObservedObject private var multipeer = MultipeerSyncService.shared
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("direct from mac")

            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("receive on local network")
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Text(multipeerCaption)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foregroundSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { multipeer.isEnabled },
                    set: { multipeer.setEnabled($0) }
                ))
                .labelsHidden()
                .tint(theme.accent)
                .accessibilityLabel("Receive notebooks on local network")
            }

            if multipeer.isEnabled {
                pairingControls
                if !multipeer.pairedPeerNames.isEmpty {
                    pairedDevicesList
                }
            }
        }
    }

    @ViewBuilder
    private var pairingControls: some View {
        if case .pairing(let code, _) = multipeer.status {
            VStack(alignment: .leading, spacing: 6) {
                Text("enter this code on the mac:")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.foregroundSubtle)
                HStack(spacing: 8) {
                    Text(code)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .tracking(4)
                        .foregroundStyle(theme.foreground)
                        .accessibilityLabel("Pairing code \(code.map { String($0) }.joined(separator: " "))")
                    Spacer()
                    Button {
                        multipeer.cancelPairing()
#if canImport(UIKit)
                        HapticManager.shared.toolSwitched()
#endif
                    } label: {
                        Text("cancel")
                            .font(.system(size: 12))
                            .foregroundStyle(theme.foregroundMuted)
                    }
                    .buttonStyle(.plain)
                }
                Text("expires in 90 seconds. only enter the code on a mac you trust.")
                    .font(.system(size: 10).italic())
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accent.opacity(0.08))
            )
        } else {
            Button {
                _ = multipeer.beginPairing()
#if canImport(UIKit)
                HapticManager.shared.toolSwitched()
#endif
            } label: {
                Text("show pairing code")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Displays a six digit code for a trusted Mac to enter")
        }
    }

    @ViewBuilder
    private var pairedDevicesList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("paired devices")
                .font(.system(size: 11))
                .foregroundStyle(theme.foregroundSubtle)
                .padding(.top, 8)
            ForEach(multipeer.pairedPeerNames, id: \.self) { name in
                HStack(spacing: 8) {
                    Circle()
                        .fill(multipeer.isPeerConnected(name) ? theme.accent : theme.recessiveTertiary)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(name)
                        .font(.system(size: 13))
                        .foregroundStyle(theme.foreground)
                    Spacer()
                    Text(multipeer.isPeerConnected(name) ? "live" : "offline")
                        .font(.system(size: 10))
                        .foregroundStyle(multipeer.isPeerConnected(name) ? theme.accent : theme.foregroundSubtle)
                    Button {
                        multipeer.forgetPeer(name)
#if canImport(UIKit)
                        HapticManager.shared.toolSwitched()
#endif
                    } label: {
                        Text("forget")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.danger)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Forget paired device \(name)")
                }
                .padding(.vertical, 6)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.hairline).frame(height: 0.5)
                }
            }
            Button {
                multipeer.forgetAllPeers()
#if canImport(UIKit)
                HapticManager.shared.toolSwitched()
#endif
            } label: {
                Text("forget all paired devices")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundMuted)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
    }

    private var multipeerCaption: String {
        switch multipeer.status {
        case .off:
            return "when on, a mac on the same wi-fi can ship notebooks directly to this device. tap show pairing code and enter it on the mac to authorise a sender. all payloads are hmac-authenticated; unpaired peers can't send anything."
        case .idle:
            return "advertising. tap show pairing code to authorise a mac for the first time."
        case .pairing:
            return "waiting for the mac to connect with the code below."
        case .connected(let name):
            return "paired with \(name). live sync when both apps are open."
        case .receiving(let name):
            return "receiving from \(name)…"
        case .received(let name, let filename):
            return "received \(filename) from \(name)."
        case .error(let msg):
            return msg
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}

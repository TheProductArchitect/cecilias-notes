import SwiftUI

/// In-app privacy policy screen. Surfaces the short plain-language
/// version first, then a link out to the canonical hosted policy
/// for users (and App Store reviewers) who want the long form.
struct PrivacyPolicyView: View {
    @Environment(\.theme) private var theme

    private static let hostedURL = URL(
        string: "https://venugopinath.me/cecilias-notes/privacy"
    )!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                shortVersion
                collectionSection
                hostedLink
            }
            .padding(.horizontal, 24)
            .padding(.top, 28)
            .padding(.bottom, 28)
        }
        .background(theme.surface)
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        Text("privacy")
            .font(.system(size: 22, weight: .heavy))
            .tracking(-0.5)
            .foregroundStyle(theme.foreground)
    }

    private var shortVersion: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("the short version")
            Text("Cecilia's Notes does not collect, store, transmit, or share any personal data. Your notes stay on your device. We have no server. We have no account system. We cannot see your notes because they never leave your iPad.")
                .font(.system(size: 14))
                .foregroundStyle(theme.foreground)
                .lineSpacing(4)
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("what we collect")
            Text("Nothing.")
                .font(.system(size: 14))
                .foregroundStyle(theme.foreground)
        }
    }

    private var hostedLink: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("full policy")
            Button {
                UIApplication.shared.open(Self.hostedURL)
            } label: {
                HStack(spacing: 6) {
                    Text(Self.hostedURL.absoluteString)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.accent)
                        .underline()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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

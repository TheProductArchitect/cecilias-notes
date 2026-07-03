import SwiftUI

/// Settings → Intelligence. Hosts the quiz feature's controls: AI
/// Features (toggles), Generation Engine (tier picker), and MCP Status.
/// Quiz generation requires Apple Intelligence or the Mac MCP helper
/// (the on-device tier was retired); the engine rows appear only when
/// their tier is present, with an explanatory line when neither is.
///
/// Editorial style matches the rest of Settings: eyebrow + heavy title +
/// hairline rule, 8pt tracked uppercase section labels, no card fills.
struct IntelligenceSettingsView: View {
    @ObservedObject private var intelligence = IntelligenceService.shared
    @ObservedObject private var mcp = MCPStatusMonitor.shared
    @Environment(\.theme) private var theme

    // Quiz preference keys (read by QuizGenerationService / the builder).
    @AppStorage("ceciliasnotes.quiz.enabled")
    private var quizEnabled: Bool = true
    @AppStorage("ceciliasnotes.quiz.autoAdd")
    private var autoAdd: Bool = false
    @AppStorage("ceciliasnotes.quiz.includeTranscriptions")
    private var includeTranscriptions: Bool = true
    @AppStorage("ceciliasnotes.quiz.engine")
    private var engineRaw: String = AITier.appleIntelligence.rawValue

    private var appleIntelligenceAvailable: Bool { intelligence.isAvailable }
    private var mcpAvailable: Bool { mcp.hasEverConnected }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                header
                aiFeatures
                generationEngine
                if mcpAvailable { mcpStatus }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
        .background(theme.surface)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("settings")
                .font(.system(size: 9, weight: .regular))
                .tracking(0.1)
                .textCase(.uppercase)
                .foregroundStyle(theme.recessiveQuaternary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("intelligence")
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundStyle(theme.foreground)
                Circle()
                    .fill(theme.accent)
                    .frame(width: 6, height: 6)
            }
            Rectangle()
                .fill(theme.foreground)
                .frame(height: 1.5)
                .padding(.top, 6)
        }
    }

    // MARK: AI Features

    private var aiFeatures: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("ai features")
            toggleRow("quiz generation", caption: nil, isOn: $quizEnabled)
            toggleRow(
                "auto-add questions",
                caption: "quizzes grow as notes grow, weekly",
                isOn: $autoAdd
            )
            toggleRow(
                "include transcriptions",
                caption: nil,
                isOn: $includeTranscriptions,
                isLast: true
            )
        }
    }

    // MARK: Generation Engine

    private var generationEngine: some View {
        // The on-device tier was retired (its pattern matcher rarely
        // produced questions) — QuizGenerationService only ever
        // resolves to Apple Intelligence or MCP now, and the builder
        // silently upgrades a persisted ".onDevice" choice. Offering
        // the retired row here let users select an engine that no
        // longer exists.
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("use for quiz generation")
            if appleIntelligenceAvailable {
                engineRow(.appleIntelligence, title: "apple intelligence", caption: "on-device · private · marks short answers")
            }
            if mcpAvailable {
                engineRow(.mcp, title: "mcp (mac required)", caption: "best quality · requires cecilias-notes-mcp running")
            }
            if !appleIntelligenceAvailable && !mcpAvailable {
                Text("quiz generation needs apple intelligence (enable it in the Settings app → apple intelligence & siri) or the mac mcp helper.")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSubtle)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 12)
            }
        }
    }

    /// Selection check treats a legacy persisted ".onDevice" as
    /// Apple Intelligence — mirrors the silent upgrade the quiz
    /// builder applies when it seeds its tier.
    private func engineRow(_ tier: AITier, title: String, caption: String) -> some View {
        let effectiveRaw = engineRaw == AITier.onDevice.rawValue
            ? AITier.appleIntelligence.rawValue
            : engineRaw
        let isSelected = effectiveRaw == tier.rawValue
        return Button {
            engineRaw = tier.rawValue
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: isSelected ? .bold : .regular))
                    .foregroundStyle(isSelected ? theme.foreground : theme.recessivePrimary)
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                if isSelected {
                    Rectangle().fill(theme.foreground).frame(width: 2)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: MCP Status

    private var mcpStatus: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("mcp status")
            HStack(spacing: 8) {
                Circle()
                    .fill(mcp.isReachable
                          ? Color(light: Color(hex: "#34c759"), dark: Color(hex: "#30d158"))
                          : theme.recessiveTertiary)
                    .frame(width: 7, height: 7)
                Text("cecilias-notes-mcp")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foreground)
                Spacer()
                Text(mcp.isReachable ? "connected" : "not reachable — is your Mac running?")
                    .font(.system(size: 12))
                    .foregroundStyle(theme.foregroundSubtle)
            }
            .padding(.vertical, 12)
        }
    }

    // MARK: Helpers

    private func toggleRow(
        _ title: String,
        caption: String?,
        isOn: Binding<Bool>,
        isLast: Bool = false
    ) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(theme.foreground)
                if let caption {
                    Text(caption)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.foregroundSubtle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(theme.accent)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
            .padding(.bottom, 6)
    }
}

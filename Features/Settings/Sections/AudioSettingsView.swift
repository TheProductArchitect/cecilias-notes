import Speech
import SwiftUI

struct AudioSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @State private var isShowingLocalePicker = false

    private var selectedLocaleName: String {
        guard !viewModel.transcriptionLocale.isEmpty else { return "System default" }
        return Locale.current.localizedString(forIdentifier: viewModel.transcriptionLocale)
            ?? viewModel.transcriptionLocale
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Ink.Spacing.lg) {
                localeCard
                autoTranscribeCard
                qualityCard
            }
            .padding(Ink.Spacing.lg)
        }
        .background(Color.inkBackgroundSecondary.ignoresSafeArea())
        .navigationTitle("Audio & Transcription")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingLocalePicker) {
            LocalePickerSheet(
                selected: viewModel.transcriptionLocale,
                locales: viewModel.supportedOnDeviceLocales()
            ) { locale in
                viewModel.transcriptionLocale = locale?.identifier ?? ""
                isShowingLocalePicker = false
            }
        }
    }

    // MARK: Locale

    private var localeCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Transcription Language")

            Button {
                isShowingLocalePicker = true
            } label: {
                HStack {
                    Text(selectedLocaleName)
                        .font(.inkBody)
                        .foregroundColor(.inkTextPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.inkTextTertiary)
                }
                .padding(Ink.Spacing.sm)
                .background(Color.inkBackgroundSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Ink.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)

            Text("Only on-device languages are shown. The internet is never used.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Auto-transcribe

    private var autoTranscribeCard: some View {
        Toggle(isOn: $viewModel.autoTranscribe) {
            Label("Auto-Transcribe", systemImage: "waveform.badge.mic")
                .font(.inkBody)
                .foregroundColor(.inkTextPrimary)
        }
        .toggleStyle(.switch)
        .tint(.inkAccentPrimary)
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    // MARK: Quality

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: Ink.Spacing.sm) {
            cardHeader("Transcription Quality")

            Picker("Quality", selection: $viewModel.transcriptionQuality) {
                ForEach(TranscriptionQuality.allCases, id: \.rawValue) { q in
                    Text(q.displayName).tag(q)
                }
            }
            .pickerStyle(.segmented)

            Text("'Accurate' uses more battery and takes longer.")
                .font(.inkCaption)
                .foregroundColor(.inkTextTertiary)
        }
        .padding(Ink.Spacing.md)
        .inkCard()
    }

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(.inkSubhead)
            .foregroundColor(.inkTextSecondary)
    }
}

// MARK: - LocalePickerSheet

private struct LocalePickerSheet: View {
    let selected: String
    let locales:  [Locale]
    let onSelect: (Locale?) -> Void

    @State private var query = ""

    private var filtered: [Locale] {
        guard !query.isEmpty else { return locales }
        let q = query.lowercased()
        return locales.filter {
            let name = Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier
            return name.lowercased().contains(q) || $0.identifier.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // System default option
                Button {
                    onSelect(nil)
                } label: {
                    HStack {
                        Text("System default")
                            .font(.inkBody)
                            .foregroundColor(.inkTextPrimary)
                        Spacer()
                        if selected.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.inkAccentPrimary)
                        }
                    }
                }
                .buttonStyle(.plain)

                ForEach(filtered, id: \.identifier) { locale in
                    Button {
                        onSelect(locale)
                    } label: {
                        HStack {
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .font(.inkBody)
                                .foregroundColor(.inkTextPrimary)
                            Spacer()
                            if selected == locale.identifier {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.inkAccentPrimary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search languages")
            .navigationTitle("Language")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onSelect(nil) }
                }
            }
        }
        .presentationDetents([.large])
    }
}

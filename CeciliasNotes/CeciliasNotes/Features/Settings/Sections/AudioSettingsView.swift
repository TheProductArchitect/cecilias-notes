import Speech
import SwiftUI

struct AudioSettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @Environment(\.theme) private var theme
    @State private var isShowingLocalePicker = false

    /// Bind the segmented picker against `@AppStorage` directly rather
    /// than routing through `viewModel.transcriptionQuality`. Same root
    /// cause as the Pencil double-tap fix in PencilSettingsView:
    /// `SettingsViewModel` has an explicit `objectWillChange` publisher
    /// (Swift 5.10 actor-isolation requirement); `@AppStorage` properties
    /// on that ObservableObject persist to UserDefaults but never fire
    /// `objectWillChange`, so the segmented Picker reads stale state and
    /// stays on the previous segment. Re-declaring `@AppStorage` here
    /// makes it a SwiftUI `DynamicProperty` that drives re-rendering.
    @AppStorage("ink.transcription.quality")
    private var transcriptionQuality: TranscriptionQuality = .fast

    private var selectedLocaleName: String {
        guard !viewModel.transcriptionLocale.isEmpty else { return "System default" }
        return Locale.current.localizedString(forIdentifier: viewModel.transcriptionLocale)
            ?? viewModel.transcriptionLocale
    }

    var body: some View {
        ScrollView {
            VStack(spacing: CeciliasNotes.Spacing.lg) {
                localeCard
                afterRecordingCard
                qualityCard
            }
            .padding(CeciliasNotes.Spacing.lg)
        }
        .background(theme.surface.ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            cardHeader("Transcription Language")

            Button {
                isShowingLocalePicker = true
            } label: {
                HStack {
                    Text(selectedLocaleName)
                        .font(.ceciliasNotesBody)
                        .foregroundColor(theme.foreground)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.ceciliasNotesRowLabel)
                        .foregroundColor(theme.foregroundSubtle)
                }
                .padding(CeciliasNotes.Spacing.sm)
                .background(theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: CeciliasNotes.Radius.sm, style: .continuous))
            }
            .buttonStyle(.ceciliasNotesPressable)

            Text("Only on-device languages are shown. The internet is never used.")
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
        }
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
    }

    // MARK: After-recording (save clip + auto-transcribe)

    /// Two independent toggles. With both ON the recording produces an
    /// audio pin and an attached transcript (default). With one OFF
    /// the corresponding artefact is skipped at stop-time. With both
    /// OFF a recording is discarded — the recording panel surfaces a
    /// subtle reminder so the user understands why nothing was saved.
    private var afterRecordingCard: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            cardHeader("After Recording")

            VStack(spacing: 0) {
                Toggle(isOn: $viewModel.saveAudioClips) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Save audio clips")
                            .font(.ceciliasNotesBody)
                            .foregroundColor(theme.foreground)
                        Text("Keep the audio so you can play it back.")
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(theme.foregroundSubtle)
                    }
                }
                .toggleStyle(.switch)
                .tint(theme.accent)
                .padding(.vertical, 10)

                Divider()

                Toggle(isOn: $viewModel.autoTranscribe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Generate transcripts")
                            .font(.ceciliasNotesBody)
                            .foregroundColor(theme.foreground)
                        Text("Convert speech to text on-device.")
                            .font(.ceciliasNotesCaption)
                            .foregroundColor(theme.foregroundSubtle)
                    }
                }
                .toggleStyle(.switch)
                .tint(theme.accent)
                .padding(.vertical, 10)
            }

            if !viewModel.saveAudioClips && !viewModel.autoTranscribe {
                Text("With both off, recordings are discarded. Turn one on to keep something.")
                    .font(.ceciliasNotesCaption)
                    .foregroundColor(theme.foregroundSubtle)
            }
        }
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
    }

    // MARK: Quality

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: CeciliasNotes.Spacing.sm) {
            cardHeader("Transcription Quality")

            Picker("Quality", selection: $transcriptionQuality) {
                ForEach(TranscriptionQuality.allCases, id: \.rawValue) { q in
                    Text(q.displayName).tag(q)
                }
            }
            .pickerStyle(.segmented)

            Text("'Accurate' uses more battery and takes longer.")
                .font(.ceciliasNotesCaption)
                .foregroundColor(theme.foregroundSubtle)
        }
        .padding(CeciliasNotes.Spacing.md)
        .ceciliasNotesCard()
    }

    private func cardHeader(_ title: String) -> some View {
        Text(title)
            .font(.ceciliasNotesSubhead)
            .foregroundColor(theme.foregroundMuted)
    }
}

// MARK: - LocalePickerSheet

private struct LocalePickerSheet: View {
    let selected: String
    let locales:  [Locale]
    let onSelect: (Locale?) -> Void
    @Environment(\.theme) private var theme

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
                            .font(.ceciliasNotesBody)
                            .foregroundColor(theme.foreground)
                        Spacer()
                        if selected.isEmpty {
                            Image(systemName: "checkmark")
                                .font(.ceciliasNotesRowSelected)
                                .foregroundColor(theme.accent)
                        }
                    }
                }
                .buttonStyle(.ceciliasNotesPressable)

                ForEach(filtered, id: \.identifier) { locale in
                    Button {
                        onSelect(locale)
                    } label: {
                        HStack {
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier)
                                .font(.ceciliasNotesBody)
                                .foregroundColor(theme.foreground)
                            Spacer()
                            if selected == locale.identifier {
                                Image(systemName: "checkmark")
                                    .font(.ceciliasNotesRowSelected)
                                    .foregroundColor(theme.accent)
                            }
                        }
                    }
                    .buttonStyle(.ceciliasNotesPressable)
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
        .presentationDetents([.medium, .large])
    }
}

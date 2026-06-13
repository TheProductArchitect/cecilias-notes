import Combine
import SwiftData
import SwiftUI

/// Slide-down customise panel anchored to the top of the editor.
/// Non-modal: the editor remains visible behind it and updates live
/// as the user picks tones, page sizes, templates. Direct manipulation
/// — no save/cancel pattern.
///
/// Phase D redesign: flat white surface, editorial section labels,
/// hairline-only inputs, the 8 `NotebookCoverTone` swatches with ghost
/// letters, template thumbnails with labels, and "done" as a text
/// button in the header (right) instead of a filled pill at the foot.
struct CustomisePanel: View {
    @ObservedObject var viewModel: EditorViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var titleBuffer: String = ""
    @FocusState private var titleFocused: Bool
    @FocusState private var nameFieldFocused: Bool

    // Tag editor — inline composer toggled by tapping "＋". When
    // visible, the TextField takes focus and commits on return.
    @State private var isAddingTag:  Bool = false
    @State private var tagBuffer:    String = ""
    @State private var tagError:     String?
    @FocusState private var tagFieldFocused: Bool

    /// Annotation list sheet presentation flag. Toggled by tapping
    /// the annotation count row when at least one annotation exists.
    @State private var showAnnotationList: Bool = false

    /// `.onReceive` tick that forces `annotationCounts()` to be
    /// re-evaluated when either side-channel store mutates. The
    /// store posts a notification on every save / softDelete /
    /// forget; bumping this state value invalidates the body and
    /// recomputes the row copy + chevron visibility live.
    @State private var annotationsTick: Int = 0

    /// Measured intrinsic height of the scroll content. The ScrollView
    /// is then capped at this height so the panel hugs its content
    /// instead of stretching to fill the available vertical space (the
    /// old behaviour left a tall band of empty surface below `TAGS` on
    /// large iPads). If content ever exceeds the screen, the parent's
    /// `maxHeight` cap kicks in and the ScrollView starts scrolling.
    @State private var contentHeight: CGFloat = 0

    private let coverSwatchSize    = CGSize(width: 64, height: 85)
    private let templateThumbSize  = CGSize(width: 64, height: 85)

    // Hairline + section-label palette migrated to Theme (D1 — Bucket 4
    // consolidation). Note: CustomisePanel's hairlineColour was slightly
    // darker than the Settings-family (#ebebeb vs #f5f5f5 light, #2a2a28
    // vs #1f1f1d dark). theme.hairline sits between the two; CustomisePanel
    // hairlines become marginally less prominent after migration. Phase G
    // can re-tune theme.hairline's alpha if the new rendering reads off.
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(showsIndicators: false) {
            // Stacked vertical layout — the earlier two-column band
            // relied on a measured row width to split 55/45, and on
            // narrower screens (iPad mini, split view) or before the
            // first geometry pass the right column collapsed and
            // hid its toggles. Single-column eliminates that whole
            // class of layout failure and matches the way the panel
            // actually reads (top → bottom: identity → cover →
            // template → behaviour → tags → annotations).
            VStack(alignment: .leading, spacing: 14) {
                suggestedTagsBanner
                nameSection
                    .overlay(alignment: .topTrailing) {
                        // Inline "done" — sits in the same row band as
                        // the name field so we don't need a dedicated
                        // header strip above the panel content (which
                        // was just an empty band of theme.surface
                        // above the first section).
                        Button {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                            commitTitle()
                            viewModel.closeCustomisePanel()
                        } label: {
                            Text("done")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.accent)
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.defaultAction)
                    }
                coverSection
                    .frame(maxWidth: .infinity, alignment: .leading)
                templateSection
                pageSizeSection
                behaviourSection
                tagsSection
                annotationsSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 16)
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: CustomisePanelContentHeightKey.self,
                        value: g.size.height
                    )
                }
            )
        }
        .frame(maxHeight: contentHeight > 0 ? contentHeight : nil)
        .onPreferenceChange(CustomisePanelContentHeightKey.self) { contentHeight = $0 }
        .background(
            UnevenRoundedRectangle(
                cornerRadii: .init(
                    topLeading: 0, bottomLeading: CeciliasNotes.Radius.lg,
                    bottomTrailing: CeciliasNotes.Radius.lg, topTrailing: 0
                ),
                style: .continuous
            )
            .fill(theme.surface)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            titleBuffer = viewModel.notebook.title
            // Always auto-focus the name field on open — the panel's
            // primary intent is "edit this notebook's identity," so
            // surfacing the keyboard immediately removes the extra
            // tap that the duplicate-title-row design used to mask.
            // The pending-focus flag is still consumed so the call
            // site doesn't think it has work left to do.
            viewModel.pendingCustomiseNameFocus = false
            DispatchQueue.main.async {
                nameFieldFocused = true
            }
        }
    }

    // Header strip retired — the empty band of theme.surface above
    // the first section read as a visible gap below the editor
    // toolbar. The "done" button moved into the name-section
    // overlay so the row band reads as one continuous surface.

    // MARK: Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("name")
            TextField("notebook name", text: $titleBuffer)
                .font(.system(size: 15))
                .foregroundStyle(theme.foreground)
                .focused($nameFieldFocused)
                .submitLabel(.done)
                .onSubmit { commitTitle() }
                .onChange(of: nameFieldFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(theme.hairline).frame(height: 0.5)
                }
                // Keyboard toolbar "Done" — single dismiss path
                // that works under floating + docked keyboards.
                // This is now the only inline TextField in the
                // notebook-naming flow; the legacy in-card
                // rename was retired in favour of routing every
                // rename through the customise panel.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") {
                            UIApplication.shared.sendAction(
                                #selector(UIResponder.resignFirstResponder),
                                to: nil, from: nil, for: nil
                            )
                        }
                        .foregroundStyle(theme.accent)
                    }
                }

            suggestedTitlePill
        }
    }

    /// AI-proposed title surfaces here when:
    ///   • Apple Intelligence is on,
    ///   • the notebook's title is still a placeholder, and
    ///   • a suggestion was generated this session.
    /// Tap to apply. Otherwise it dismisses when the user commits a
    /// manual title.
    @ViewBuilder
    private var suggestedTitlePill: some View {
        if let suggestion = viewModel.suggestedTitle {
            Button {
                viewModel.applySuggestedTitle()
                titleBuffer = viewModel.notebook.title
            } label: {
                HStack(spacing: 6) {
                    Text("→")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.recessiveTertiary)
                    Text(suggestion)
                        .font(.system(size: 11))
                        .foregroundStyle(theme.foreground)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(theme.hairline))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Apply suggested title: \(suggestion)")
        }
    }

    // MARK: AI — suggested tags banner

    /// AI proposes 1–3 tags for an untagged notebook. Banner sits
    /// at the top of the panel — "suggested: pill pill pill — add
    /// all / dismiss". Dismiss is sticky per notebook (the banner
    /// never reappears for that notebook).
    @ViewBuilder
    private var suggestedTagsBanner: some View {
        if !viewModel.suggestedTags.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text("suggested")
                        .font(.system(size: 9, weight: .regular).italic())
                        .foregroundStyle(theme.recessiveQuaternary)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(viewModel.suggestedTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 11))
                                .foregroundStyle(theme.foreground)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(
                                    Capsule()
                                        .strokeBorder(
                                            theme.hairline,
                                            lineWidth: 0.5
                                        )
                                )
                        }
                    }
                }

                HStack(spacing: 14) {
                    Button { viewModel.applyAllSuggestedTags() } label: {
                        Text("add all")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.accent)
                    }
                    .buttonStyle(.plain)

                    Button { viewModel.dismissSuggestedTags() } label: {
                        Text("dismiss")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.recessiveTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.bottom, 4)
        }
    }

    // MARK: Tags

    /// Free-form, lowercase tags. Up to 20 per notebook, ≤32 chars
    /// each, no emoji / digits — same validation as subject names.
    /// Persisted via `Notebook.tags` (backed by the existing
    /// `tagsRaw` SwiftData column), so this is a UI surface over an
    /// already-additive schema field. No tag sync, no analytics —
    /// tag mutations stay on-device.
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("tags")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // Empty-state placeholder: "add tags" italic in
                    // recessive tertiary, sitting inline with the
                    // `+` button so the row reads as intentional
                    // instead of an orphaned chip. The placeholder
                    // collapses out the moment the user adds a tag.
                    if viewModel.notebook.tags.isEmpty && !isAddingTag {
                        Text("add tags")
                            .font(.system(size: 12).italic())
                            .foregroundStyle(theme.recessiveTertiary)
                    }

                    ForEach(viewModel.notebook.tags, id: \.self) { tag in
                        tagPill(tag)
                    }

                    if isAddingTag {
                        inlineTagComposer
                    } else {
                        addTagButton
                    }
                }
                .padding(.vertical, 2)
            }

            if let tagError {
                Text(tagError)
                    .font(.system(size: 9, weight: .regular).italic())
                    .foregroundStyle(Color.red.opacity(0.75))
            }
        }
    }

    private func tagPill(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .font(.system(size: 12))
            Button {
                removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove tag \(tag)")
        }
        .foregroundStyle(Color(light: .white, dark: Color.coverTextBlack))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                Color(light: Color.coverTextBlack, dark: Color(hex: "#f5f5f5"))
            )
        )
    }

    private var addTagButton: some View {
        Button {
            tagBuffer  = ""
            tagError   = nil
            isAddingTag = true
            DispatchQueue.main.async { tagFieldFocused = true }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.recessivePrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .overlay(
                    Capsule().strokeBorder(theme.hairline, lineWidth: 0.5)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add tag")
    }

    private var inlineTagComposer: some View {
        HStack(spacing: 4) {
            TextField("tag", text: $tagBuffer)
                .font(.system(size: 12))
                .focused($tagFieldFocused)
                .submitLabel(.done)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { commitTagBuffer() }
                .onChange(of: tagFieldFocused) { _, focused in
                    if !focused { commitTagBuffer() }
                }
                .frame(minWidth: 60, maxWidth: 120)
            Button {
                cancelTagComposer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel tag entry")
        }
        .foregroundStyle(theme.foreground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().strokeBorder(theme.accent, lineWidth: 0.8)
        )
    }

    private func commitTagBuffer() {
        defer {
            tagBuffer   = ""
            isAddingTag = false
        }
        let existing = viewModel.notebook.tags
        switch TagValidator.validate(tagBuffer, against: existing) {
        case .success(let normal):
            var updated = existing
            updated.append(normal)
            viewModel.notebook.tags = updated
            viewModel.persistTags()
            tagError = nil
        case .failure(.empty):
            tagError = nil       // cancel-by-empty is silent
        case .failure(.tooLong):
            tagError = "tag is too long (max 32 chars)."
        case .failure(.containsDigit):
            tagError = "tags can't include numbers."
        case .failure(.containsEmoji):
            tagError = "tags can't include emoji."
        case .failure(.duplicate):
            tagError = nil       // duplicates silently rejected per spec
        case .failure(.tooManyTags):
            tagError = "20-tag limit reached."
        }
    }

    private func cancelTagComposer() {
        tagBuffer   = ""
        tagError    = nil
        isAddingTag = false
    }

    private func removeTag(_ tag: String) {
        let current = viewModel.notebook.tags
        guard let idx = current.firstIndex(of: tag) else { return }
        var updated = current
        updated.remove(at: idx)
        viewModel.notebook.tags = updated
        viewModel.persistTags()
        tagError = nil
    }

    // MARK: Cover

    private static let coverPalette: [NotebookCoverTone] = [
        .parchment, .studioWhite, .ash, .coal,
        .midnight, .moss, .dusk, .inkBlack
    ]

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("cover")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Self.coverPalette, id: \.self) { tone in
                        coverSwatch(tone)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func coverSwatch(_ tone: NotebookCoverTone) -> some View {
        let isSelected = viewModel.notebook.coverTone == tone
        let firstChar  = viewModel.notebook.title.first ?? "n"

        return Button {
            viewModel.notebook.coverTone = tone
            HapticManager.shared.toolSwitched()
        } label: {
            ZStack {
                tone.background

                // Ghost letter — preview of how the card actually
                // looks. Bleeds bottom-right same as the card itself.
                GhostLetter(
                    character: firstChar,
                    size: 56,
                    onDarkBackground: !tone.isLight
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .offset(x: 8, y: 8)
                .clipped()
            }
            .frame(width: coverSwatchSize.width, height: coverSwatchSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? theme.accent
                            : (tone.requiresBorder ? theme.hairline : Color.clear),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Cover \(toneLabel(tone))")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func toneLabel(_ tone: NotebookCoverTone) -> String {
        switch tone {
        case .parchment:    return "Parchment"
        case .studioWhite:  return "Studio White"
        case .ash:          return "Ash"
        case .coal:         return "Coal"
        case .midnight:     return "Midnight"
        case .moss:         return "Moss"
        case .dusk:         return "Dusk"
        case .inkBlack:     return "Ink Black"
        }
    }

    // MARK: Page size

    private var pageSizeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("page size")
            HStack(spacing: 0) {
                ForEach(Array(PageSize.allCases.enumerated()), id: \.element) { index, size in
                    let isSelected = viewModel.notebook.pageSize == size
                    Button {
                        viewModel.applyCustomPageSize(size)
                        HapticManager.shared.toolSwitched()
                    } label: {
                        Text(size.displayName.lowercased())
                            .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                            .foregroundStyle(
                                isSelected
                                    ? theme.foreground
                                    : Color(light: Color(hex: "#aaaaaa"),
                                            dark:  Color(hex: "#5e5e5c"))
                            )
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < PageSize.allCases.count - 1 {
                        Rectangle()
                            .fill(theme.hairline)
                            .frame(width: 0.5, height: 18)
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
    }

    // MARK: Template

    /// Template is a creation-time decision: once any page has strokes
    /// the selector becomes read-only. Step 8: the byte-counter
    /// short-cut (`page.strokeDataSize`) is gone with the
    /// `Page.strokeData` field. Read each page's stroke blob via
    /// the V6 storage helper — still cheap (no PKDrawing decode,
    /// just a SwiftData fetch + byte-emptiness check per page).
    private var canChangeTemplate: Bool {
        let pages = viewModel.notebook.pages ?? []
        return pages.allSatisfy {
            (StorageService.shared.strokeData(for: $0)?.isEmpty ?? true)
        }
    }

    private var templateSection: some View {
        let locked = !canChangeTemplate
        return VStack(alignment: .leading, spacing: 14) {
            sectionLabel("page template")

            // Categorised picker: each category gets its own
            // horizontal scroll strip with a small italic header. The
            // 18 templates cover ranges of behaviour (lined / dotted /
            // grid / specialised / planning), so a single flat
            // carousel was getting unwieldy.
            ForEach(TemplateCategory.allCases, id: \.self) { category in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.displayName)
                        .font(.system(size: 9, weight: .regular).italic())
                        .foregroundStyle(theme.recessiveQuaternary)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(PageTemplate.allCases.filter { $0.category == category },
                                    id: \.self) { template in
                                templateThumbnail(template, locked: locked)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            if locked {
                Text("set when you started writing")
                    .font(.system(size: 9, weight: .regular).italic())
                    .foregroundStyle(theme.recessiveQuaternary)
            }
        }
    }

    @ViewBuilder
    private func templateThumbnail(_ template: PageTemplate, locked: Bool) -> some View {
        let isSelected = isCurrentTemplate(template)
        VStack(spacing: 6) {
            Button {
                guard !locked else { return }
                viewModel.applyCustomTemplate(template)
                HapticManager.shared.toolSwitched()
            } label: {
                TemplateThumbView(template: template, size: templateThumbSize)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(
                                isSelected ? theme.accent : theme.hairline,
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
                    .opacity(locked && !isSelected ? 0.4 : 1.0)
            }
            .buttonStyle(.plain)
            .disabled(locked && !isSelected)

            Text(template.displayName.lowercased())
                .font(.system(size: 8).italic())
                .foregroundStyle(theme.recessiveQuaternary)
        }
        .accessibilityLabel("Template \(template.displayName)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(locked ? "Locked — set when you started writing" : "")
    }

    // MARK: Annotations (PDF notebooks only)

    /// Read-only summary row for PDF-backed notebooks. Surfaces the
    /// per-notebook annotation count so the user can see what they've
    /// added without having to scrub the page strip. Counts sticky
    /// notes plus PDF text annotations (highlight / underline /
    /// strikethrough). Tapping the row is a no-op today — it's the
    /// entry point for Pass C (annotation list sheet).
    private var annotationsSection: some View {
        // `annotationsTick` participates in the read so the body
        // re-renders when the store notifies. The actual fetch is in
        // `annotationCounts()` — cheap enough to run on every redraw.
        let _ = annotationsTick
        let counts = annotationCounts()
        let total = counts.highlights + counts.underlines + counts.strikethroughs + counts.stickyNotes
        let isTappable = total > 0

        return VStack(alignment: .leading, spacing: 0) {
            sectionLabel("annotations")
                .padding(.bottom, 4)
            HStack(alignment: .center, spacing: 0) {
                Text(annotationsSummary(counts))
                    .font(.system(size: 13))
                    .foregroundStyle(theme.foreground)
                Spacer(minLength: 8)
                // Chevron — only when there's something to drill in
                // to. Recessive-tertiary at 12pt, matching the
                // recessive-row-affordance pattern used elsewhere.
                if isTappable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(theme.recessiveTertiary)
                }
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .onTapGesture {
                guard isTappable else { return }
                showAnnotationList = true
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(theme.hairline).frame(height: 0.5)
            }
        }
        // Phase 5B: AnnotationListSheet is presented through
        // `ModalPresenter` so it lifts above the editor's
        // `.fullScreenCover` from `LibraryView` rather than nesting
        // a sheet inside the cover. The trigger boolean
        // `showAnnotationList` is preserved so existing button
        // wiring is unchanged; the .onChange below translates flag
        // flips into presenter calls.
        .onChange(of: showAnnotationList) { _, newValue in
            guard newValue else { return }
            ModalPresenter.shared.present(.sheet(
                id: "editor.annotationList",
                onDidDismiss: { showAnnotationList = false }
            ) {
                AnnotationListSheet(viewModel: viewModel) {
                    ModalPresenter.shared.dismiss()
                }
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            })
        }
        // Live recompute when either store mutates. `annotationsTick`
        // is bumped on each post; the body's `let _ = ...` read
        // above forces the section to re-render.
        .onReceive(
            NotificationCenter.default.publisher(for: .highlightElementsChanged)
        ) { _ in annotationsTick &+= 1 }
        .onReceive(
            NotificationCenter.default.publisher(for: .stickyNotesChanged)
        ) { _ in annotationsTick &+= 1 }
    }

    /// Aggregated counts for the annotations row. Walks every
    /// non-soft-deleted page of the notebook and tallies each
    /// surface separately. Step 7: stickies are V6
    /// `PageElement(.stickyNote)` rows alongside highlights — both
    /// flow through the same per-page PageElement fetch.
    /// Multi-line highlight groups collapse to one count (matches
    /// what the user sees in the annotation list).
    private struct AnnotationCounts {
        var highlights:     Int
        var underlines:     Int
        var strikethroughs: Int
        var stickyNotes:    Int
    }

    private func annotationCounts() -> AnnotationCounts {
        var highlights = 0, underlines = 0, strikethroughs = 0, stickyNotes = 0
        let context = StorageService.shared.context
        for page in (viewModel.notebook.pages ?? []) where !page.isDeleted {
            let pid = page.id
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.pageId == pid && $0.deletedAt == nil
                }
            )
            let elements = (try? context.fetch(descriptor)) ?? []
            var seenGroups: Set<UUID> = []
            for element in elements where element.kind == .highlight {
                guard let content = element.highlightContent else { continue }
                if let groupId = content.groupId {
                    if seenGroups.contains(groupId) { continue }
                    seenGroups.insert(groupId)
                }
                switch content.style {
                case .highlight:     highlights += 1
                case .underline:     underlines += 1
                case .strikethrough: strikethroughs += 1
                }
            }
            for element in elements where element.kind == .stickyNote {
                stickyNotes += 1
                _ = element  // explicitly silenced — count-only walk
            }
        }
        return AnnotationCounts(
            highlights:     highlights,
            underlines:     underlines,
            strikethroughs: strikethroughs,
            stickyNotes:    stickyNotes
        )
    }

    /// "3 highlights · 2 underlines · 1 strikethrough · 1 note" —
    /// singular-aware, zero counts dropped, joined by " · ".
    /// "no annotations yet." when every count is zero.
    private func annotationsSummary(_ counts: AnnotationCounts) -> String {
        var parts: [String] = []
        if counts.highlights > 0 {
            parts.append("\(counts.highlights) " +
                         (counts.highlights == 1 ? "highlight" : "highlights"))
        }
        if counts.underlines > 0 {
            parts.append("\(counts.underlines) " +
                         (counts.underlines == 1 ? "underline" : "underlines"))
        }
        if counts.strikethroughs > 0 {
            parts.append("\(counts.strikethroughs) " +
                         (counts.strikethroughs == 1 ? "strikethrough" : "strikethroughs"))
        }
        if counts.stickyNotes > 0 {
            parts.append("\(counts.stickyNotes) " +
                         (counts.stickyNotes == 1 ? "note" : "notes"))
        }
        if parts.isEmpty { return "no annotations yet." }
        return parts.joined(separator: " · ")
    }

    // MARK: Auto-add / auto-hide compact rows
    //
    // Both toggles are single-line 44pt rows — label on the left,
    // `Toggle` on the right, hairline separator at the bottom. The
    // per-toggle descriptions that used to sit under each label are
    // consolidated into one recessive caption (`togglesCaption`)
    // mounted right below the band so the panel keeps its overall
    // height down.

    /// "Behaviour" block — full-width rows that hold their own toggles
    /// without depending on a measured column split. Replaces the
    /// earlier two-column band where the toggles disappeared when
    /// the right column collapsed before the first geometry pass.
    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("behaviour")
                .padding(.bottom, 4)
            toggleRow(
                label:   "auto-add pages",
                binding: autoAddBinding
            )
            toggleRow(
                label:   "auto-hide top bar",
                binding: autoHideBinding
            )
            togglesCaption
        }
    }

    private func toggleRow(label: String, binding: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(theme.foreground)
            Spacer(minLength: 0)
            Toggle("", isOn: binding)
                .labelsHidden()
                .tint(theme.accent)
        }
        .frame(height: 44)
        .overlay(alignment: .bottom) {
            Rectangle().fill(theme.hairline).frame(height: 0.5)
        }
    }

    /// Shared recessive caption explaining both consolidated toggles.
    /// 10pt `inkRecessiveTertiary` so it reads as supplementary,
    /// not chrome.
    private var togglesCaption: some View {
        Text("auto-add: new page when scrolling near bottom · auto-hide: hides toolbar while writing")
            .font(.system(size: 10))
            .foregroundStyle(theme.recessiveTertiary)
            .padding(.top, 6)
    }

    private var autoAddBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notebook.autoAddPagesOnScroll },
            set: { viewModel.notebook.autoAddPagesOnScroll = $0 }
        )
    }

    private var autoHideBinding: Binding<Bool> {
        Binding(
            get: { viewModel.notebook.autoHideHeader },
            set: {
                viewModel.notebook.autoHideHeader = $0
                viewModel.notifyAutoHidePreferenceChanged()
            }
        )
    }

    // MARK: Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }

    private func commitTitle() {
        viewModel.renameNotebook(titleBuffer)
        titleBuffer = viewModel.notebook.title
        // The user committed a real title — dismiss any pending AI
        // suggestion. The suggestion would no longer be relevant.
        viewModel.dismissSuggestedTitle()
    }

    private func isCurrentTemplate(_ template: PageTemplate) -> Bool {
        template == viewModel.notebook.defaultTemplate
    }
}

// PageTemplate.displayName lives on the type itself now (see
// SupportingTypes.swift) — the local extension was removed when the
// enum gained the property natively.

private struct CustomisePanelContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Measures the width of the template / right-column row band so
/// the columns can be sized at explicit fractional widths. Without
/// an explicit width cap the template carousel's intrinsic width
/// dominates and the right column collapses.
private struct CustomisePanelRowWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

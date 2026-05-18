import SwiftUI

/// SwiftUI overlay that renders the active page's sticky notes and —
/// when the sticky-note tool is the selected tool — claims taps to
/// place fresh ones.
///
/// Two interaction modes:
///   • **Browse** (any tool other than `.stickyNote`): empty-area
///     taps pass through to PKCanvasView. Each existing marker is
///     individually tappable to open the popover editor.
///   • **Placement** (`.stickyNote` active): a full-bleed clear
///     layer claims every tap and converts it to a new note at the
///     normalised location. Existing markers still take priority
///     (you can tap an old note to edit it rather than dropping a
///     fresh one on top).
struct StickyNotesOverlayView: View {
    @ObservedObject var viewModel: EditorViewModel
    /// The page this overlay is mounted on. Per-page mount per the
    /// architectural rule — renders only notes whose `pageId` matches.
    let pageId: UUID
    /// Single placement primitive, base size only. See
    /// `Documentation/MEDIA_SUBSYSTEM_AUDIT.md` §6.A.
    let coordinateSpace: PageCoordinateSpace

    /// Refresh tick — bumped when `.stickyNotesChanged` fires so the
    /// per-page lookup re-runs without polling the store.
    @State private var refreshTick: Int = 0

    var body: some View {
        let _ = refreshTick
        let pageSize = coordinateSpace.baseSize
        let notes    = StickyNoteStore.notes(for: pageId)

        ZStack(alignment: .topLeading) {
            // Placement layer — only present when the sticky-note
            // tool is active. SwiftUI z-stacks new content above
            // earlier content, so the layer sits BELOW the
            // existing markers and lets marker taps win.
            if viewModel.selectedTool.isStickyNoteMode {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        placeNote(at: location, in: pageSize)
                    }
            }

            ForEach(notes) { note in
                StickyNoteMarker(
                    note: note,
                    isOpen: viewModel.editingStickyNoteId == note.id,
                    viewModel: viewModel
                )
                .position(
                    x: CGFloat(note.normalizedX) * pageSize.width,
                    y: CGFloat(note.normalizedY) * pageSize.height
                )
            }
        }
        .frame(width: pageSize.width, height: pageSize.height, alignment: .topLeading)
        .onReceive(
            NotificationCenter.default.publisher(for: .stickyNotesChanged)
        ) { _ in refreshTick &+= 1 }
    }

    private func placeNote(at location: CGPoint, in size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewModel.addStickyNote(
            on: pageId,
            at: CGPoint(x: location.x / size.width, y: location.y / size.height)
        )
    }
}

// MARK: - Marker

/// The folded-corner square that represents a sticky note on the
/// page. Tapping opens the popover editor.
private struct StickyNoteMarker: View {
    let note: StickyNoteRecord
    let isOpen: Bool
    @ObservedObject var viewModel: EditorViewModel

    private static let size: CGFloat = 24

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The body fill + the folded corner are the only
            // chromatic surface in the whole app outside of cover
            // tones. See `Color.stickyNoteFill` for the rationale.
            Rectangle()
                .fill(Color.stickyNoteFill)
                .frame(width: Self.size, height: Self.size)
                .overlay(
                    // 0.5pt outline so the marker stays visible on a
                    // pale PDF page.
                    Rectangle().strokeBorder(
                        Color.stickyNoteFold,
                        lineWidth: 0.5
                    )
                )

            // Folded top-right corner — same as a paper post-it.
            Path { p in
                p.move(to: CGPoint(x: Self.size - 7, y: 0))
                p.addLine(to: CGPoint(x: Self.size, y: 0))
                p.addLine(to: CGPoint(x: Self.size, y: 7))
                p.closeSubpath()
            }
            .fill(Color.stickyNoteFold)
        }
        .frame(width: Self.size, height: Self.size)
        // Pulse signal shared with PageRenderer's text-annotation
        // overlay. `viewModel.pulsingAnnotationId` is the single
        // signal; we scale this marker briefly when its id matches.
        // SwiftUI animates the scale change with the explicit
        // animation modifier below.
        .scaleEffect(viewModel.pulsingAnnotationId == note.id ? 1.1 : 1.0)
        .animation(
            .easeOut(duration: 0.30),
            value: viewModel.pulsingAnnotationId
        )
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.editingStickyNoteId = note.id
        }
        .popover(
            isPresented: Binding(
                get: { isOpen },
                set: { open in
                    if !open && viewModel.editingStickyNoteId == note.id {
                        viewModel.editingStickyNoteId = nil
                    }
                }
            ),
            arrowEdge: .bottom
        ) {
            StickyNotePopoverEditor(note: note, viewModel: viewModel)
        }
        .accessibilityLabel(
            note.body.isEmpty
                ? Text("Empty sticky note")
                : Text("Sticky note: \(note.body)")
        )
        .accessibilityHint(Text("Tap to edit"))
    }
}

// MARK: - Popover editor

/// Plain TextEditor with a hairline border — no rounded-rect bubble,
/// no system shadow, no background fill. Matches the inline title
/// editor in the customise panel exactly: 11pt SF Pro regular,
/// editorial recessive hierarchy. "remove" text button bottom-
/// trailing in `inkRecessiveTertiary`, same pattern as the "done"
/// dismiss in the settings sheet.
private struct StickyNotePopoverEditor: View {
    let note: StickyNoteRecord
    @ObservedObject var viewModel: EditorViewModel

    @State private var draft: String = ""
    @FocusState private var focused: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("sticky note")

            TextEditor(text: $draft)
                .font(.system(size: 11))
                .foregroundStyle(theme.foreground)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($focused)
                .frame(minWidth: 220, minHeight: 100)
                .overlay(
                    Rectangle()
                        .stroke(theme.recessiveQuinary, lineWidth: 0.5)
                )

            HStack {
                Spacer()
                Button {
                    viewModel.deleteStickyNote(id: note.id)
                } label: {
                    Text("remove")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.recessiveTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 260)
        .background(theme.surfaceElevated)
        .onAppear {
            draft = note.body
            focused = true
        }
        .onChange(of: draft) { _, newValue in
            viewModel.updateStickyNoteBody(id: note.id, body: newValue)
        }
        .presentationCompactAdaptation(.popover)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8))
            .tracking(0.08)
            .textCase(.uppercase)
            .foregroundStyle(theme.recessiveQuaternary)
    }
}

// MARK: - Palette

/// The **only chromatic colour in the app chrome outside cover tones.**
///
/// Reasoning: every other surface (page chrome, customise panel,
/// settings, library cards, masthead) is monochrome — black / white /
/// recessive greys — with colour reserved for notebook cover tones
/// and the brand-accent dot. Sticky notes are an exception by
/// necessity: a marker on a PDF page needs to be visible against the
/// document's own typography, and a near-black square on a paper-
/// white PDF reads as a censor bar, not an annotation. A muted
/// yellow-amber (the universally-recognised post-it palette) gives
/// the marker a "this is a note, not part of the document" signal
/// without introducing decorative colour anywhere else in the app.
/// The fold colour is a slightly darker amber so the folded-corner
/// shape reads at the 24×24 marker size.
private extension Color {
    static let stickyNoteFill = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.93, green: 0.84, blue: 0.45, alpha: 1.0)  // #ECD672
                : UIColor(red: 0.99, green: 0.92, blue: 0.55, alpha: 1.0)  // #FCEB8C
        }
    )
    static let stickyNoteFold = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.79, green: 0.69, blue: 0.32, alpha: 1.0)  // #C9B051
                : UIColor(red: 0.91, green: 0.81, blue: 0.39, alpha: 1.0)  // #E8CF63
        }
    )
}

/// AnnotationListSheet.swift
/// Cecilia's Notes
///
/// Pass C of the PDF-annotation feature set: the half-height sheet
/// the customise panel's annotation count row opens. Lists every
/// active sticky note + PDF text annotation in the current notebook
/// in one sorted view; row taps navigate to the page and pulse the
/// mark; swipe-left removes (soft-delete only).
///
/// No persisted model — `AnnotationListItem` is a pure view-model
/// enum that wraps either a `StickyNoteRecord` or a
/// `PDFTextAnnotationRecord` plus the resolved page number. Live
/// refresh on `.stickyNotesChanged` + `.pdfTextAnnotationsChanged`.

import SwiftUI

// MARK: - AnnotationListItem (view-model only)

/// Unified row item for the list. Carries the resolved
/// `pageNumber` so the sort + display can avoid re-looking-up the
/// `Page` for every row redraw.
enum AnnotationListItem: Identifiable, Hashable {
    case textAnnotation(PDFTextAnnotationRecord, pageNumber: Int)
    case stickyNote(StickyNoteRecord, pageNumber: Int)

    var id: UUID {
        switch self {
        case .textAnnotation(let r, _): return r.id
        case .stickyNote(let r, _):     return r.id
        }
    }

    var pageNumber: Int {
        switch self {
        case .textAnnotation(_, let n), .stickyNote(_, let n): return n
        }
    }

    var createdAt: Date {
        switch self {
        case .textAnnotation(let r, _): return r.createdAt
        case .stickyNote(let r, _):     return r.createdAt
        }
    }

    /// Truncated to 60 chars. Used as the secondary line on every
    /// row.
    var snippet: String {
        let raw: String
        switch self {
        case .textAnnotation(let r, _): raw = r.selectedText
        case .stickyNote(let r, _):     raw = r.body
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    /// 2pt leading rule colour — the only type signal in the row.
    /// Yellow for the three PDF text annotation kinds, muted amber
    /// for sticky notes (the same colour the editor uses for the
    /// in-canvas marker).
    var typeColour: Color {
        switch self {
        case .textAnnotation:
            return .yellow
        case .stickyNote:
            // Sole chromatic exception documented in the design
            // system. Matches the sticky-note marker on the canvas.
            return Color(red: 0.96, green: 0.78, blue: 0.34)
        }
    }
}

// MARK: - Sheet

struct AnnotationListSheet: View {
    @ObservedObject var viewModel: EditorViewModel
    let onDismiss: () -> Void

    /// Tick to force a re-fetch when either store changes. SwiftUI
    /// doesn't redraw on `NotificationCenter` posts by itself; the
    /// observers below bump this value so `items` recomputes.
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(.systemBackground))
        .onReceive(
            NotificationCenter.default.publisher(for: .pdfTextAnnotationsChanged)
        ) { _ in refreshTick &+= 1 }
        .onReceive(
            NotificationCenter.default.publisher(for: .stickyNotesChanged)
        ) { _ in refreshTick &+= 1 }
    }

    // MARK: Header

    /// 22pt heavy heading, "done" trailing button, 1.5pt edge-to-edge
    /// rule. Same shape as Settings and Ask My Notes — keeps the
    /// editorial typography consistent across sheets.
    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 0) {
                Text("annotations")
                    .font(.system(size: 22, weight: .heavy))
                    .tracking(-0.5)
                    .foregroundStyle(Color.inkTextPrimary)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("done")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.brandAccent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            Rectangle()
                .fill(Color.inkTextPrimary)
                .frame(height: 1.5)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        // `refreshTick` is read inside the computation so the
        // `.onReceive` ticks force a fresh fetch.
        let _ = refreshTick
        let rows = items()
        if rows.isEmpty {
            emptyState
        } else {
            list(rows)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 60)
            Text("no annotations yet.")
                .font(.system(size: 11).italic())
                .foregroundStyle(Color.inkRecessiveTertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func list(_ rows: [AnnotationListItem]) -> some View {
        // List gets us free `.swipeActions(...)` per row plus the
        // smooth animate-out the spec calls for. The list chrome is
        // suppressed to match the rest of the app's editorial style.
        List {
            ForEach(rows) { row in
                AnnotationRow(item: row) {
                    handleTap(row)
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .frame(height: 56)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button {
                        softDelete(row)
                    } label: {
                        // "remove" — matches the app's language
                        // pattern (sticky-note popover, attachment
                        // overflow). Never "delete" or hard-delete;
                        // soft-delete only.
                        Text("remove")
                    }
                    .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemBackground))
    }

    // MARK: Data

    /// Loads every active record from both stores for every page in
    /// the notebook and returns them sorted by page number, then by
    /// creation time. Computed on every body redraw — the row count
    /// is bounded by what fits in UserDefaults JSON, so a full walk
    /// is cheap enough not to need caching.
    private func items() -> [AnnotationListItem] {
        var out: [AnnotationListItem] = []
        for page in viewModel.pages where !page.isDeleted {
            let pageNumber = page.pageNumber
            for record in PDFTextAnnotationStore.records(for: page.id) {
                out.append(.textAnnotation(record, pageNumber: pageNumber))
            }
            for note in StickyNoteStore.notes(for: page.id) {
                out.append(.stickyNote(note, pageNumber: pageNumber))
            }
        }
        return out.sorted { lhs, rhs in
            if lhs.pageNumber != rhs.pageNumber {
                return lhs.pageNumber < rhs.pageNumber
            }
            return lhs.createdAt < rhs.createdAt
        }
    }

    // MARK: Row actions

    private func handleTap(_ item: AnnotationListItem) {
        // Capture id + pageNumber up front so the dismiss can run
        // first and the pulse fires against the freshly-scrolled
        // canvas. Order matters: dismiss → navigate → pulse.
        let id = item.id
        let pageNumber = item.pageNumber
        onDismiss()
        viewModel.revealAnnotation(id: id, pageNumber: pageNumber)
    }

    private func softDelete(_ item: AnnotationListItem) {
        switch item {
        case .textAnnotation(let record, _):
            PDFTextAnnotationStore.softDelete(id: record.id, pageId: record.pageId)
            // Also clear the in-memory PDFAnnotation so the canvas
            // overlay reflects the removal without waiting for the
            // debounced disk writer.
            viewModel.pdfAnnotationWriter?.removeFromInMemoryDocument(
                recordId: record.id,
                pdfPageIndex: record.pdfPageIndex
            )
            viewModel.pdfAnnotationWriter?.scheduleWrite()
        case .stickyNote(let note, _):
            StickyNoteStore.softDelete(id: note.id, pageId: note.pageId)
        }
        // Both stores post their respective `.*Changed` notifications
        // inside the mutation; the sheet refreshes via `onReceive`
        // and the customise panel count row reads live, so no
        // explicit refresh call is needed here.
    }
}

// MARK: - Row

/// Fixed-height (56pt) row. Three elements: 2pt leading colour rule,
/// page-number + snippet stack, trailing timestamp. No icons.
private struct AnnotationRow: View {
    let item: AnnotationListItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(item.typeColour)
                    .frame(width: 2)
                    .padding(.trailing, 12)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("page \(item.pageNumber)")
                            .font(.system(size: 11))
                            .foregroundColor(.inkRecessiveSecondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    Text(item.snippet.isEmpty ? " " : item.snippet)
                        .font(.system(size: 13))
                        .foregroundColor(.inkTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(Self.timestamp(item.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(.inkRecessiveTertiary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "today" / "yesterday" / "d MMM". Mirrors the home grid's
    /// recessive date treatment so the row language is consistent.
    private static func timestamp(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date)     { return "today" }
        if cal.isDateInYesterday(date) { return "yesterday" }
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f.string(from: date).lowercased()
    }
}

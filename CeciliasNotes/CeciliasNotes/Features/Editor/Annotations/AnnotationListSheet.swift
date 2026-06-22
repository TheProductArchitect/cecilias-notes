/// AnnotationListSheet.swift
/// Cecilia's Notes
///
/// Pass C of the PDF-annotation feature set: the half-height sheet
/// the customise panel's annotation count row opens. Lists every
/// active sticky note + highlight in the current notebook in one
/// sorted view; row taps navigate to the page and pulse the mark;
/// swipe-left removes (soft-delete only).
///
/// No persisted model — `AnnotationListItem` is a pure view-model
/// enum carrying snapshot fields for either a highlight or a
/// sticky-note row (both now V6 `PageElement` rows after Step 7).
/// Live refresh on `.stickyNotesChanged` + `.highlightElementsChanged`.

import SwiftData
import SwiftUI

// MARK: - AnnotationListItem (view-model only)

/// Unified row item for the list. Carries the resolved
/// `pageNumber` so the sort + display can avoid re-looking-up the
/// `Page` for every row redraw.
///
/// Step 5.5: highlights now arrive as V6
/// `PageElement(.highlight) + HighlightContent`. Carries the
/// snapshot data the row needs (id, captured text, createdAt,
/// page) rather than the @Model instance so the enum stays
/// Hashable / Sendable.
enum AnnotationListItem: Identifiable, Hashable {
    case textAnnotation(
        id: UUID,
        capturedText: String,
        createdAt: Date,
        pageId: UUID,
        pageNumber: Int,
        groupId: UUID?
    )
    /// Step 7: stickies are now V6 `PageElement(.stickyNote) +
    /// StickyNoteContent`. The case carries snapshot fields
    /// (mirrors `.textAnnotation`) so the enum stays Hashable /
    /// Sendable without referencing the @Model row.
    case stickyNote(
        id: UUID,
        body: String,
        createdAt: Date,
        pageId: UUID,
        pageNumber: Int
    )

    var id: UUID {
        switch self {
        case .textAnnotation(let id, _, _, _, _, _): return id
        case .stickyNote(let id, _, _, _, _):        return id
        }
    }

    var pageNumber: Int {
        switch self {
        case .textAnnotation(_, _, _, _, let n, _): return n
        case .stickyNote(_, _, _, _, let n):        return n
        }
    }

    var createdAt: Date {
        switch self {
        case .textAnnotation(_, _, let d, _, _, _): return d
        case .stickyNote(_, _, let d, _, _):        return d
        }
    }

    /// Truncated to 60 chars. Used as the secondary line on every
    /// row.
    var snippet: String {
        let raw: String
        switch self {
        case .textAnnotation(_, let text, _, _, _, _): raw = text
        case .stickyNote(_, let body, _, _, _):        raw = body
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 60 { return trimmed }
        return String(trimmed.prefix(60)) + "…"
    }

    /// 2pt leading rule colour — the only type signal in the row.
    var typeColour: Color {
        switch self {
        case .textAnnotation:
            return .yellow
        case .stickyNote:
            return Color(red: 0.96, green: 0.78, blue: 0.34)
        }
    }
}

// MARK: - Sheet

struct AnnotationListSheet: View {
    @ObservedObject var viewModel: EditorViewModel
    let onDismiss: () -> Void
    @Environment(\.theme) private var theme

    /// Tick to force a re-fetch when either store changes. SwiftUI
    /// doesn't redraw on `NotificationCenter` posts by itself; the
    /// observers below bump this value so `items` recomputes.
    @State private var refreshTick: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(theme.surface)
        .onReceive(
            NotificationCenter.default.publisher(for: .highlightElementsChanged)
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
                    .foregroundStyle(theme.foreground)
                Spacer()
                Button {
                    onDismiss()
                } label: {
                    Text("done")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(theme.accent)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)
            Rectangle()
                .fill(theme.foreground)
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
                .foregroundStyle(theme.recessiveTertiary)
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
        .background(theme.surface)
    }

    // MARK: Data

    /// Loads every active highlight + sticky for every page in the
    /// notebook. Step 5.5: highlights come from V6
    /// `PageElement(.highlight) + HighlightContent` rather than
    /// the retired `PDFTextAnnotationStore`. Multi-line groups
    /// collapse to one row (first rect of each group) so the
    /// list reads as one highlight per user-visible selection.
    private func items() -> [AnnotationListItem] {
        var out: [AnnotationListItem] = []
        let context = StorageService.shared.context

        for page in viewModel.pages where !page.isDeleted {
            let pageNumber = page.pageNumber
            let pid = page.id
            let descriptor = FetchDescriptor<PageElement>(
                predicate: #Predicate<PageElement> {
                    $0.pageId == pid && $0.deletedAt == nil
                },
                sortBy: [SortDescriptor(\.createdAt)]
            )
            let elements = (try? context.fetch(descriptor)) ?? []
            // Collapse multi-line highlight groups — only emit the
            // first element per groupId. Standalone (groupId nil)
            // emits every time.
            var seenGroups: Set<UUID> = []
            for element in elements where element.kind == .highlight {
                guard let content = element.highlightContent else { continue }
                if let groupId = content.groupId {
                    if seenGroups.contains(groupId) { continue }
                    seenGroups.insert(groupId)
                }
                out.append(.textAnnotation(
                    id: element.id,
                    capturedText: content.capturedText ?? "",
                    createdAt: element.createdAt,
                    pageId: page.id,
                    pageNumber: pageNumber,
                    groupId: content.groupId
                ))
            }
            for element in elements where element.kind == .stickyNote {
                guard let content = element.stickyNoteContent else { continue }
                out.append(.stickyNote(
                    id:         element.id,
                    body:       content.text,
                    createdAt:  element.createdAt,
                    pageId:     page.id,
                    pageNumber: pageNumber
                ))
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
        let id = item.id
        let pageNumber = item.pageNumber
        onDismiss()
        viewModel.revealAnnotation(id: id, pageNumber: pageNumber)
    }

    private func softDelete(_ item: AnnotationListItem) {
        switch item {
        case .textAnnotation(let elementId, _, _, _, _, let groupId):
            // Group → soft-delete every member at once; standalone →
            // soft-delete only this element. Either path posts
            // `.highlightElementsChanged` so the sheet refreshes.
            if let groupId {
                HighlightCommit.deleteHighlightGroup(groupId: groupId)
            } else {
                let context = StorageService.shared.context
                let descriptor = FetchDescriptor<PageElement>(
                    predicate: #Predicate { $0.id == elementId }
                )
                if let element = try? context.fetch(descriptor).first {
                    element.deletedAt = Date()
                    element.updatedAt = Date()
                    do {
                        try context.save()
                    } catch {
                        #if DEBUG
                        dlog("[Annotations] highlight delete SAVE FAILED elementId=\(elementId): \(error)")
                        #endif
                    }
                    NotificationCenter.default.post(
                        name: .highlightElementsChanged, object: nil
                    )
                }
            }
        case .stickyNote(let elementId, _, _, _, _):
            StickyNoteCommit.softDelete(elementId: elementId)
        }
    }
}

// MARK: - Row

/// Fixed-height (56pt) row. Three elements: 2pt leading colour rule,
/// page-number + snippet stack, trailing timestamp. No icons.
private struct AnnotationRow: View {
    let item: AnnotationListItem
    let onTap: () -> Void
    @Environment(\.theme) private var theme

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
                            .foregroundColor(theme.recessiveSecondary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    Text(item.snippet.isEmpty ? " " : item.snippet)
                        .font(.system(size: 13))
                        .foregroundColor(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                Text(Self.timestamp(item.createdAt))
                    .font(.system(size: 10))
                    .foregroundColor(theme.recessiveTertiary)
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

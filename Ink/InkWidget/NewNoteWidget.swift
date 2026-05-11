import SwiftUI
import WidgetKit

// MARK: - Cecilia's Notes — widget set
//
// Five widget configurations, all driven by `InkWidgetProvider`'s
// `NotebookEntry`:
//
//   • Home small      — quick-capture tile with the brand mark.
//   • Home medium     — quick-capture + 3 recents.
//   • Lock circular   — pure quick-capture dot for the lock screen.
//   • Lock rectangular — last-opened notebook title + quick-capture.
//   • Lock inline      — single-line recent-notebook tap target.
//
// Design language (shared across every widget):
//   • Background flips with the system appearance — #0a0a0a dark /
//     #ffffff light.
//   • Typography is SF Pro Display only: heavy (800) for the brand
//     name, regular (400) everywhere else.
//   • Brand mark is the user's possessive ("[name]'s notes·") with
//     the blue middle dot. Reads `user.displayName` from the App
//     Group `UserDefaults`; falls back to "cecilia's notes·".
//   • Ghost letter is the first character of the user's name (or
//     "c"), 5% opacity, heavy, bleeding off the bottom-right edge.
//   • Accent colour is system blue (`#007AFF` light / `#0A84FF`
//     dark) and only ever paints the brand middle dot and the
//     "new note" label.
//   • Lock-screen variants are `.widgetAccentable()`-tagged on the
//     brand dot so the OS's accent tint resolves correctly under
//     both full-colour and vibrant rendering.
//
// No borders, no rounded rects beyond the system widget corner
// radius, no icons. Every tap target deep-links via the existing
// `ink://` scheme (`quick-capture` or `open/{uuid}`).

// MARK: - Home small (.systemSmall)

struct HomeSmallNewNoteWidget: Widget {
    let kind: String = "CeciliasNotes.HomeSmallNewNote"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            HomeSmallView(entry: entry)
                .containerBackground(for: .widget) { Color.cnBackground }
        }
        .configurationDisplayName("Cecilia's Notes — New Note")
        .description("One tap to a fresh notebook.")
        .supportedFamilies([.systemSmall])
    }
}

private struct HomeSmallView: View {
    let entry: NotebookEntry

    var body: some View {
        ZStack {
            GhostLetter()
            VStack(alignment: .leading, spacing: 4) {
                Spacer(minLength: 0)
                BrandPossessive(size: 28)
                Text("new note")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundColor(.cnAccent)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .widgetURL(URL(string: "ink://quick-capture"))
    }
}

// MARK: - Home medium (.systemMedium)

struct HomeMediumRecentsWidget: Widget {
    let kind: String = "CeciliasNotes.HomeMediumRecents"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            HomeMediumView(entry: entry)
                .containerBackground(for: .widget) { Color.cnBackground }
        }
        .configurationDisplayName("Cecilia's Notes — Recents")
        .description("Quick capture plus your three most recent notebooks.")
        .supportedFamilies([.systemMedium])
    }
}

private struct HomeMediumView: View {
    let entry: NotebookEntry

    var body: some View {
        HStack(spacing: 0) {
            // Left — quick-capture half.
            Link(destination: URL(string: "ink://quick-capture")!) {
                ZStack {
                    GhostLetter()
                    VStack(alignment: .leading, spacing: 4) {
                        Spacer(minLength: 0)
                        BrandPossessive(size: 26)
                        Text("new note")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.cnAccent)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.cnHairline)
                .frame(width: 0.5)

            // Right — recents.
            VStack(alignment: .leading, spacing: 0) {
                Text("recent")
                    .font(.system(size: 8, weight: .regular))
                    .tracking(0.08)
                    .textCase(.uppercase)
                    .foregroundColor(.cnRecessive)
                    .padding(.bottom, 6)

                ForEach(entry.recents.prefix(3), id: \.id) { nb in
                    if let url = URL(string: "ink://open/\(nb.id.uuidString)") {
                        Link(destination: url) { recentRow(nb) }
                    } else {
                        recentRow(nb)
                    }
                }

                if entry.recents.isEmpty {
                    Text("no notebooks yet")
                        .font(.system(size: 11).italic())
                        .foregroundColor(.cnRecessive)
                        .padding(.top, 6)
                }

                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func recentRow(_ nb: NotebookSummary) -> some View {
        Text(nb.title)
            .font(.system(size: 13, weight: .regular))
            .foregroundColor(.cnPrimary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 5)
    }
}

// MARK: - Lock circular (.accessoryCircular)

struct LockCircularNewNoteWidget: Widget {
    let kind: String = "CeciliasNotes.LockCircularNewNote"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { _ in
            LockCircularView()
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cecilia's Notes — New Note")
        .description("One-tap fresh notebook from the lock screen.")
        .supportedFamilies([.accessoryCircular])
    }
}

private struct LockCircularView: View {
    var body: some View {
        VStack(spacing: 2) {
            // The brand dot — tinted by the system's lock-screen
            // accent treatment via `.widgetAccentable()`.
            Text("·")
                .font(.system(size: 36, weight: .heavy))
                .widgetAccentable()
            Text("new")
                .font(.system(size: 11, weight: .regular))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetURL(URL(string: "ink://quick-capture"))
    }
}

// MARK: - Lock rectangular (.accessoryRectangular)

struct LockRectangularLastNotebookWidget: Widget {
    let kind: String = "CeciliasNotes.LockRectangularLastNotebook"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            LockRectangularView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Cecilia's Notes — Last Notebook")
        .description("New note plus your most recent notebook on the lock screen.")
        .supportedFamilies([.accessoryRectangular])
    }
}

private struct LockRectangularView: View {
    let entry: NotebookEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            BrandPossessive(size: 13)
            Text(entry.primary?.title ?? "no notebooks yet")
                .font(.system(size: 12, weight: .regular))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .widgetURL(URL(string: "ink://quick-capture"))
    }
}

// MARK: - Lock inline (.accessoryInline)

struct LockInlineRecentWidget: Widget {
    let kind: String = "CeciliasNotes.LockInlineRecent"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InkWidgetProvider()) { entry in
            LockInlineView(entry: entry)
        }
        .configurationDisplayName("Cecilia's Notes — Recent Notebook")
        .description("Tap to open your most recent notebook.")
        .supportedFamilies([.accessoryInline])
    }
}

private struct LockInlineView: View {
    let entry: NotebookEntry

    private var inlineText: String {
        if let title = entry.primary?.title { return "· \(title)" }
        return "cecilia's notes·"
    }

    private var inlineURL: URL? {
        if let id = entry.primary?.id {
            return URL(string: "ink://open/\(id.uuidString)")
        }
        return URL(string: "ink://quick-capture")
    }

    var body: some View {
        Text(inlineText)
            .widgetURL(inlineURL)
    }
}

// MARK: - Brand possessive (widget-local replica)

/// The widget bundle can't import the main app's design-system
/// types, so the wordmark is reproduced here. Visual contract:
/// heavy possessive, recessive "notes" text, accent middle dot.
private struct BrandPossessive: View {
    let size: CGFloat

    @AppStorage("user.displayName", store: UserDefaults(suiteName: "group.com.wave.venu.Ink"))
    private var sharedName: String = ""

    private var displayName: String {
        let trimmed = sharedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return first.lowercased()
    }

    private var possessive: String {
        let raw = displayName.isEmpty ? "cecilia" : displayName
        return raw.hasSuffix("s") ? "\(raw)'" : "\(raw)'s"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(possessive)
                .font(.system(size: size, weight: .heavy))
                .tracking(-0.05 * size)
                .foregroundColor(.cnPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            HStack(spacing: 0) {
                Text("notes")
                    .foregroundColor(.cnRecessive)
                Text("·")
                    .foregroundColor(.cnAccent)
                    .widgetAccentable()
            }
            .font(.system(size: size * 0.28, weight: .regular))
        }
    }
}

// MARK: - Ghost letter

/// 5% opacity, heavy weight first-letter of the user's name. Sits
/// behind the brand mark and bleeds off the bottom-right edge.
private struct GhostLetter: View {

    @AppStorage("user.displayName", store: UserDefaults(suiteName: "group.com.wave.venu.Ink"))
    private var sharedName: String = ""

    private var letter: String {
        let trimmed = sharedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let first = trimmed.lowercased().first.map(String.init) ?? "c"
        return first
    }

    var body: some View {
        Text(letter)
            .font(.system(size: 140, weight: .heavy))
            .tracking(-7)
            .foregroundColor(.cnPrimary.opacity(0.05))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(x: 20, y: 20)
            .accessibilityHidden(true)
    }
}

// MARK: - Palette (Cecilia's Notes)

private extension Color {
    /// Near-black on light, near-white on dark.
    static let cnPrimary: Color = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor.white
                : UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        }
    )

    /// Recessive copy — 50% opacity of the foreground.
    static let cnRecessive: Color = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.5)
                : UIColor(white: 0, alpha: 0.5)
        }
    )

    /// System blue — fixed light/dark variants so the brand dot
    /// doesn't drift when the OS tweaks its system accent.
    static let cnAccent: Color = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.52, blue: 1.0, alpha: 1)
                : UIColor(red: 0.0,  green: 0.48, blue: 1.0, alpha: 1)
        }
    )

    /// Hairline divider colour for the medium widget's centre rule.
    static let cnHairline: Color = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.08)
                : UIColor(white: 0, alpha: 0.08)
        }
    )

    /// Container background — pure black on dark, pure white on
    /// light. The home widgets paint this; the lock-screen widgets
    /// use the system's `.fill.tertiary` container background
    /// instead so they read against the wallpaper material.
    static let cnBackground: Color = Color(
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
                : UIColor.white
        }
    )
}

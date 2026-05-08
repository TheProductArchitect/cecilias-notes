import SwiftUI
import WidgetKit

// MARK: - QuickCaptureWidget

/// Lock-screen widget that opens Ink directly into a brand-new notebook
/// ready for input.
///
/// Tap → `ink://quick-capture` → main app's `DeepLinkRouter` flips
/// `pendingQuickCapture = true` → `LibraryView` creates a notebook with a
/// playful default name and presents the editor.
///
/// Static — no timeline data needed. Provider returns a single placeholder
/// entry; the widget UI is purely a glyph + label.
struct QuickCaptureWidget: Widget {
    let kind: String = "QuickCaptureWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: kind,
            provider: QuickCaptureProvider()
        ) { _ in
            QuickCaptureWidgetView()
        }
        .configurationDisplayName("Quick Capture")
        .description("Open Ink straight into a new notebook.")
        // Lock Screen surfaces only.
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

// MARK: - Provider

private struct QuickCapturePlaceholderEntry: TimelineEntry {
    let date: Date = Date()
}

private struct QuickCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCapturePlaceholderEntry {
        QuickCapturePlaceholderEntry()
    }
    func getSnapshot(in context: Context, completion: @escaping (QuickCapturePlaceholderEntry) -> Void) {
        completion(QuickCapturePlaceholderEntry())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCapturePlaceholderEntry>) -> Void) {
        // One static entry — never refreshes. The widget has no time-varying state.
        completion(Timeline(entries: [QuickCapturePlaceholderEntry()], policy: .never))
    }
}

// MARK: - View

private struct QuickCaptureWidgetView: View {

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryRectangular:
                rectangular
            default:
                circular        // Defensive — supportedFamilies excludes anything else
            }
        }
        .widgetURL(URL(string: "ink://quick-capture"))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    // MARK: Circular — pen-tip glyph in a ring

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: "pencil.tip")
                .font(.system(size: 22, weight: .medium))
        }
    }

    // MARK: Rectangular — glyph + "Quick Capture" label

    private var rectangular: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.tip")
                .font(.system(size: 18, weight: .medium))
            VStack(alignment: .leading, spacing: 2) {
                Text("Quick Capture")
                    .font(.headline)
                Text("New notebook")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

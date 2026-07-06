import SwiftUI

struct MacKeyboardShortcutsView: View {
    @Environment(\.theme) private var theme

    private let rows: [(String, String)] = [
        ("New notebook", "⌘N"),
        ("New subject", "⌘⇧N"),
        ("Open most recent", "⌘⇧O"),
        ("Search library", "⌘F"),
        ("Search in notebook", "⌘⇧F"),
        ("Command palette", "⌘K"),
        ("Settings", "⌘,"),
        ("Toggle sidebar", "⌘⌥S"),
        ("Quick capture", "⌥⌘Space"),
        ("Export", "⌘E"),
        ("Print", "⌘P"),
        ("Add page", "⌘⇧P"),
        ("Copy page as image", "⌘⇧C"),
        ("Actual size", "⌘0"),
        ("Insert text", "⌘T"),
        ("Quick look notebook", "Space"),
        ("Open selected notebook", "↩"),
    ]

    var body: some View {
        Form {
            ForEach(rows, id: \.0) { row in
                LabeledContent(row.0) {
                    Text(row.1)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(theme.foregroundMuted)
                }
            }
        }
        .formStyle(.grouped)
    }
}

import Foundation
import UIKit

// MARK: - ToolSettings

/// Per-tool persisted settings. One entry per `CeciliasNotesTool.Identity`. The tool's
/// associated values (`colour`, `width`, `opacity`) are reconstructed from
/// the entry when the user switches tools.
///
/// `colourHex` round-trips through `UIColor(hex:)`; the existing pattern in
/// `CeciliasNotesColors.swift`. Width and opacity are plain numbers.
struct ToolSettings: Codable, Equatable {
    var colourHex: String
    var width: CGFloat
    var opacity: CGFloat
}

// MARK: - ToolSettingsStore

/// Backs the per-tool persisted settings as a single JSON blob in
/// `@AppStorage("ceciliasnotes.tool.settings")` — one key for the whole app.
///
/// Why one blob instead of one AppStorage per tool:
///   • Adding new tool variants doesn't require touching UserDefaults.
///   • A single read at editor mount restores everything.
///   • Easy to wipe via `Settings → Storage → Reset Tools` (future).
///
/// The store is a value type — read it, mutate it, write it back. Concurrent
/// access is serialised by the main actor where the editor lives.
struct ToolSettingsStore: Codable, Equatable {

    /// Settings keyed by `CeciliasNotesTool.Identity.rawValue`. A missing key means
    /// "use the default for that identity".
    var settings: [String: ToolSettings] = [:]

    /// Per-colour-group remembered colour. Width / opacity stay
    /// per-identity in `settings` (each ink type has its own
    /// natural stroke weight), but colour is shared across the
    /// "ink" group so squeeze-switching between pen / pencil /
    /// crayon / etc. carries the user's last picked colour.
    /// Highlighter has its own group key. Keyed by
    /// `CeciliasNotesTool.Identity.colourGroup`.
    var groupColourHex: [String: String] = [:]

    static let userDefaultsKey = "ceciliasnotes.tool.settings"

    // MARK: Load / save

    static func load() -> ToolSettingsStore {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode(ToolSettingsStore.self, from: data)
        else {
            return ToolSettingsStore()
        }
        return decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        }
    }

    // MARK: Lookup

    func settings(for identity: CeciliasNotesTool.Identity) -> ToolSettings? {
        settings[identity.rawValue]
    }

    mutating func set(_ entry: ToolSettings, for identity: CeciliasNotesTool.Identity) {
        settings[identity.rawValue] = entry
    }

    /// Snapshot the current associated values of an `CeciliasNotesTool` into a
    /// persisted entry. No-op for tools without colour/width/opacity.
    /// Also writes the tool's colour to the shared colour-group
    /// bucket so a squeeze-switch to a sibling tool in the same
    /// group picks the same colour up.
    mutating func snapshot(_ tool: CeciliasNotesTool) {
        guard tool.hasColour || tool.hasWidth else { return }
        let entry = ToolSettings(
            colourHex: tool.currentColour.hexString,
            width:     tool.currentWidth,
            opacity:   tool.currentOpacity
        )
        set(entry, for: tool.identity)
        if tool.hasColour, let group = tool.identity.colourGroup {
            groupColourHex[group] = tool.currentColour.hexString
        }
    }

    // MARK: Apply

    /// Builds an `CeciliasNotesTool` for `identity`, restoring persisted settings if
    /// available. Falls back to `CeciliasNotesTool.Defaults.forIdentity(_:theme:)` for
    /// any field that isn't stored.
    ///
    /// Colour resolution prefers the colour-group bucket (so all
    /// ink tools share the user's last picked colour) and falls
    /// back to the per-identity stored colour, then the default.
    func tool(for identity: CeciliasNotesTool.Identity, theme: Theme) -> CeciliasNotesTool {
        let baseDefault = CeciliasNotesTool.Defaults.forIdentity(identity, theme: theme)
        let stored = settings[identity.rawValue]

        var t = baseDefault
        if t.hasColour {
            if let group = identity.colourGroup, let hex = groupColourHex[group] {
                t = t.withColour(UIColor(hex: hex))
            } else if let hex = stored?.colourHex {
                t = t.withColour(UIColor(hex: hex))
            }
        }
        if t.hasWidth,   let w = stored?.width   { t = t.withWidth(w) }
        if t.hasOpacity, let o = stored?.opacity { t = t.withOpacity(o) }
        return t
    }
}

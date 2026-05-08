import Foundation
import UIKit

// MARK: - ToolSettings

/// Per-tool persisted settings. One entry per `InkTool.Identity`. The tool's
/// associated values (`colour`, `width`, `opacity`) are reconstructed from
/// the entry when the user switches tools.
///
/// `colourHex` round-trips through `UIColor(hex:)`; the existing pattern in
/// `InkColors.swift`. Width and opacity are plain numbers.
struct ToolSettings: Codable, Equatable {
    var colourHex: String
    var width: CGFloat
    var opacity: CGFloat
}

// MARK: - ToolSettingsStore

/// Backs the per-tool persisted settings as a single JSON blob in
/// `@AppStorage("ink.tool.settings")` — one key for the whole app.
///
/// Why one blob instead of one AppStorage per tool:
///   • Adding new tool variants doesn't require touching UserDefaults.
///   • A single read at editor mount restores everything.
///   • Easy to wipe via `Settings → Storage → Reset Tools` (future).
///
/// The store is a value type — read it, mutate it, write it back. Concurrent
/// access is serialised by the main actor where the editor lives.
struct ToolSettingsStore: Codable, Equatable {

    /// Settings keyed by `InkTool.Identity.rawValue`. A missing key means
    /// "use the default for that identity".
    var settings: [String: ToolSettings] = [:]

    static let userDefaultsKey = "ink.tool.settings"

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

    func settings(for identity: InkTool.Identity) -> ToolSettings? {
        settings[identity.rawValue]
    }

    mutating func set(_ entry: ToolSettings, for identity: InkTool.Identity) {
        settings[identity.rawValue] = entry
    }

    /// Snapshot the current associated values of an `InkTool` into a
    /// persisted entry. No-op for tools without colour/width/opacity.
    mutating func snapshot(_ tool: InkTool) {
        guard tool.hasColour || tool.hasWidth else { return }
        let entry = ToolSettings(
            colourHex: tool.currentColour.hexString,
            width:     tool.currentWidth,
            opacity:   tool.currentOpacity
        )
        set(entry, for: tool.identity)
    }

    // MARK: Apply

    /// Builds an `InkTool` for `identity`, restoring persisted settings if
    /// available. Falls back to `InkTool.Defaults.forIdentity(_:theme:)` for
    /// any field that isn't stored.
    func tool(for identity: InkTool.Identity, theme: InkTheme) -> InkTool {
        let baseDefault = InkTool.Defaults.forIdentity(identity, theme: theme)
        guard let stored = settings[identity.rawValue] else { return baseDefault }
        let colour = UIColor(hex: stored.colourHex)

        // Apply stored fields onto the default — any property that doesn't
        // apply to this tool is a no-op via the corresponding `with…` helper.
        var t = baseDefault
        if t.hasColour  { t = t.withColour(colour) }
        if t.hasWidth   { t = t.withWidth(stored.width) }
        if t.hasOpacity { t = t.withOpacity(stored.opacity) }
        return t
    }
}

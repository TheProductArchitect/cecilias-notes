import Foundation

// MARK: - ToolCategoryStore

/// Maps each `ToolCategory` to the variant the user most recently picked
/// inside it. Persisted as JSON in `@AppStorage("ink.tool.lastVariantPerCategory")`.
///
/// Why a top-level enum instead of an `ObservableObject`:
///   • Read/write happens in three places (palette tap, popover pick,
///     view-model identity-switch hook). A static API is the simplest
///     shared surface.
///   • The map is small (≤4 entries today) so encoding it on every write
///     is fine.
enum ToolCategoryStore {
    private static let key = "ink.tool.lastVariantPerCategory"

    /// Returns the last-used variant for `category`, or its default if the
    /// user has never picked a variant in this category yet.
    static func lastVariant(for category: ToolCategory) -> InkTool.Identity {
        let map = loadMap()
        if let raw      = map[category.rawValue],
           let identity = InkTool.Identity(rawValue: raw),
           category.variants.contains(identity) {
            return identity
        }
        return category.defaultVariant
    }

    /// Records `identity` as the last-used variant for its category.
    /// No-op for identities that don't belong to a category (eraser, lasso, …).
    static func setLastVariant(_ identity: InkTool.Identity) {
        guard let category = identity.category else { return }
        var map = loadMap()
        map[category.rawValue] = identity.rawValue
        if let data = try? JSONEncoder().encode(map) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func loadMap() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}

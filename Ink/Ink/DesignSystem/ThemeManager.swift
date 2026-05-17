import SwiftUI
import Combine

// MARK: - Theme definition

public enum CeciliasNotesTheme: String, CaseIterable, Codable {
    case light = "light"
    case dark  = "dark"
    // Designed for extension — add .sepia, .highContrast etc here in future.
    // ThemePickerView uses ForEach(CeciliasNotesTheme.allCases) so adding a theme
    // requires zero structural changes to the UI.

    public var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        }
    }

    public var displayName: String {
        switch self {
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    public var previewBackground: Color {
        switch self {
        case .light: return Color(UIColor(hex: "#FAFAF8"))
        case .dark:  return Color(UIColor(hex: "#111110"))
        }
    }

    public var previewText: Color {
        switch self {
        case .light: return Color(UIColor(hex: "#1D1D1B"))
        case .dark:  return Color(UIColor(hex: "#F5F5F2"))
        }
    }

    public var previewAccent: Color {
        switch self {
        case .light: return Color(UIColor(hex: "#007AFF"))
        case .dark:  return Color(UIColor(hex: "#0A84FF"))
        }
    }

    public var previewStroke: Color {
        switch self {
        case .light: return Color(UIColor(hex: "#1D1D1B")).opacity(0.72)
        case .dark:  return Color(UIColor(hex: "#F5F5F2")).opacity(0.72)
        }
    }
}

// MARK: - Theme manager

@MainActor
public final class ThemeManager: ObservableObject {

    /// Backing `@AppStorage` — must be a primitive (String) for the macro to
    /// synthesise ObservableObject conformance under @MainActor isolation in
    /// Swift 5.10. Public callers go through the `theme` computed property below.
    /// UserDefaults key remains `ink.theme`, so persisted values from previous
    /// builds round-trip unchanged.
    @AppStorage("ink.theme") private var storedTheme: String = CeciliasNotesTheme.light.rawValue

    /// Public theme accessor. Setter manually fires `objectWillChange` so any
    /// SwiftUI views observing this `@StateObject` / `@EnvironmentObject` re-render.
    public var theme: CeciliasNotesTheme {
        get { CeciliasNotesTheme(rawValue: storedTheme) ?? .light }
        set {
            objectWillChange.send()
            storedTheme = newValue.rawValue
            applyTheme()
        }
    }

    public init() {}

    public func applyTheme() {
        let style: UIUserInterfaceStyle = theme == .dark ? .dark : .light
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .forEach { $0.overrideUserInterfaceStyle = style }
    }
}

import SwiftUI
import UIKit

/// Single source of truth for what the current device is allowed to
/// do. iPad runs the full editor (the historical behaviour);
/// iPhone runs a **responsive read-only companion** — browse +
/// read notebooks, no writing, drawing, recording, or mutation.
///
/// The split is by `UIDevice.current.userInterfaceIdiom`. Phones
/// don't have Apple Pencil, the editor's tablet-class layout
/// doesn't make sense in a phone-shaped frame, and "view your
/// notes on your phone" is the realistic v1 phone experience
/// without spending weeks on a dedicated phone UI.
///
/// **Guarantee on iPad.** Every property here returns the same
/// value it returned before this type existed — `idiom == .pad`
/// short-circuits `canMutate` to `true`, so every gated UI control
/// renders normally and every gated mutation runs. iPad behaviour
/// is mechanically unchanged.
///
/// **Defense in depth.** Mutations gate on the booleans BOTH in
/// the view layer (`.mutationOnly()` hides the control) AND in the
/// model layer (`guard DeviceCapabilities.canMutate else { … }`).
/// A view-only gate would still let a keyboard shortcut / deep
/// link / hot-reload edge case fire the mutation; a model-only
/// gate would leave dead buttons on screen. Both together leave
/// no surface to break through.
enum DeviceCapabilities {

    // MARK: - Primary axis

    /// True when the device may create / edit / delete content.
    /// iPad: always true. iPhone: always false (read-only).
    /// All other capability properties below derive from this so a
    /// future override (lock-down mode, "kids' iPad" toggle) flips
    /// the whole surface from one place.
    static var canMutate: Bool {
        UIDevice.current.userInterfaceIdiom != .phone
    }

    // MARK: - Derived feature gates

    /// True when the user can stroke ink on a page. iPhone has no
    /// Apple Pencil so the canvas would be inert anyway; we hide
    /// the chrome rather than show a dead surface.
    static var canDraw: Bool { canMutate }

    /// True when the user can start dictation / voice notes /
    /// lecture recordings. Read-only devices skip the mic
    /// affordances entirely — there's no on-page text element to
    /// route the transcript into.
    static var canRecord: Bool { canMutate }

    /// True when the user can edit notebook metadata (title,
    /// subject, tone, page template, page size). The customise
    /// panel still renders on read-only devices as an info panel
    /// — fields show but become non-interactive.
    static var canEditMetadata: Bool { canMutate }

    /// True when the user can drop new notebooks / subjects /
    /// quizzes from the library sidebar.
    static var canCreateInLibrary: Bool { canMutate }

    /// True when the library + sidebar should lay out in their
    /// full tablet form. iPhone gets a single-column grid and a
    /// collapsed sidebar that surfaces via NavigationLink.
    static var prefersTabletLayout: Bool { canMutate }

    /// Convenience inverse — reads better at call sites that
    /// branch on the read-only path (`if isReadOnly { … }`).
    static var isReadOnly: Bool { !canMutate }
}

// MARK: - SwiftUI environment

private struct DeviceCapabilitiesKey: EnvironmentKey {
    static let defaultValue: DeviceCapabilitiesProxy = .live
}

/// Indirection over the static `DeviceCapabilities` namespace so
/// SwiftUI previews + tests can override the values. Production
/// code reads through the environment via `@Environment(\.capabilities)`,
/// which resolves to `.live` (the static implementation) by
/// default.
struct DeviceCapabilitiesProxy {
    var canMutate: Bool
    var canDraw: Bool
    var canRecord: Bool
    var canEditMetadata: Bool
    var canCreateInLibrary: Bool
    var prefersTabletLayout: Bool
    var isReadOnly: Bool { !canMutate }

    static let live = DeviceCapabilitiesProxy(
        canMutate:           DeviceCapabilities.canMutate,
        canDraw:             DeviceCapabilities.canDraw,
        canRecord:           DeviceCapabilities.canRecord,
        canEditMetadata:     DeviceCapabilities.canEditMetadata,
        canCreateInLibrary:  DeviceCapabilities.canCreateInLibrary,
        prefersTabletLayout: DeviceCapabilities.prefersTabletLayout
    )

    /// Preview / test override that pins the device to read-only
    /// regardless of which simulator the preview's running on.
    static let readOnly = DeviceCapabilitiesProxy(
        canMutate: false, canDraw: false, canRecord: false,
        canEditMetadata: false, canCreateInLibrary: false,
        prefersTabletLayout: false
    )
}

extension EnvironmentValues {
    /// Read-side: `@Environment(\.capabilities) private var capabilities`.
    /// Most call sites should prefer this over the static
    /// `DeviceCapabilities` so they're override-able in previews.
    var capabilities: DeviceCapabilitiesProxy {
        get { self[DeviceCapabilitiesKey.self] }
        set { self[DeviceCapabilitiesKey.self] = newValue }
    }
}

// MARK: - View modifier

extension View {

    /// Hide the receiver entirely when the current device cannot
    /// mutate state. Use on every "create" / "edit" / "delete"
    /// affordance so the UI never shows a button that does
    /// nothing. iPad: no-op (always renders). iPhone: never
    /// renders.
    ///
    /// Example:
    ///
    ///     Button("+ new notebook") { create() }
    ///         .mutationOnly()
    @ViewBuilder
    func mutationOnly() -> some View {
        if DeviceCapabilities.canMutate { self }
    }

    /// Variant that disables but doesn't hide — for controls
    /// whose presence is informational (e.g. the customise panel's
    /// fields render as displayed values but can't be edited).
    func mutationDisabled(_ extra: Bool = false) -> some View {
        disabled(!DeviceCapabilities.canMutate || extra)
    }
}

import SwiftUI
import UIKit

/// Single source of truth for what the current device is allowed to
/// do.
///
/// **Two independent axes**:
///
/// 1. *Form factor* (`isPhoneIdiom`, `prefersTabletLayout`). Drives
///    layout — sidebar drawer vs inline, grid density, masthead
///    height. Decided purely by `UIDevice.userInterfaceIdiom`.
///
/// 2. *Capabilities* (`canMutate`, `canDraw`, `canRecord`, …). What
///    the user is allowed to *do*. These are independent of layout
///    so an iPhone can have a compact masthead AND let the user
///    rename a notebook, while still keeping the PencilKit canvas
///    disabled (no Apple Pencil on iPhone).
///
/// **iPhone today**: light editing — text, metadata, notebook /
/// subject creation. NO drawing (no Pencil), NO lecture
/// recording (iPad-class workflow).
///
/// **iPad today**: full editor. Every property below returns the
/// same value it returned when this type was introduced; iPad
/// behaviour is mechanically unchanged.
///
/// **Defense in depth.** Mutations gate on the booleans BOTH in
/// the view layer (`.mutationOnly()` hides the control) AND in the
/// model layer (`guard DeviceCapabilities.canMutate else { … }`).
/// A view-only gate would still let a keyboard shortcut / deep
/// link / hot-reload edge case fire the mutation; a model-only
/// gate would leave dead buttons on screen. Both together leave
/// no surface to break through.
enum DeviceCapabilities {

    // MARK: - Form factor (layout signal, independent of capability)

    /// True on iPhone (compact-class device). Used by layouts
    /// that need to switch between iPad's side-by-side composition
    /// and iPhone's stacked / drawer composition. *Never* gates
    /// mutations — see `canMutate` for that.
    static var isPhoneIdiom: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// True when the library + sidebar should lay out in their
    /// full tablet form. iPhone gets a single-column grid and a
    /// collapsed sidebar that surfaces via a drawer overlay.
    /// Mirrors `!isPhoneIdiom`; kept as a named concept so future
    /// form factors (iPhone Pro Max in landscape, fold devices)
    /// can adopt the tablet layout independently of the idiom.
    static var prefersTabletLayout: Bool { !isPhoneIdiom }

    // MARK: - Capabilities (what the user is allowed to do)

    /// True when the device may create / edit / delete content.
    /// iPad: always true. iPhone: true — light editing was enabled
    /// in the iPhone-support phase (2026-06).
    static var canMutate: Bool { true }

    /// True when the user can stroke ink on a page. iPhone has no
    /// Apple Pencil, so the PKCanvasView is hidden / inert and
    /// the tool palette doesn't render. iPad: always true.
    static var canDraw: Bool { !isPhoneIdiom }

    /// True when the user can start dictation / voice notes /
    /// lecture recordings. iPad-class workflow — the live
    /// transcript + lecture pane don't make sense on a phone-shaped
    /// frame yet, so iPhone hides the mic affordances entirely.
    static var canRecord: Bool { !isPhoneIdiom }

    /// True when the user can edit notebook metadata (title,
    /// subject, tags, page template, page size). Enabled on
    /// every device — phone users still need to rename notebooks
    /// and tag them, even without drawing.
    static var canEditMetadata: Bool { true }

    /// True when the user can create new notebooks / subjects /
    /// quizzes from the library sidebar. Enabled on every device.
    static var canCreateInLibrary: Bool { true }

    /// Convenience inverse — reads better at call sites that
    /// branch on the read-only path. Today no shipping device is
    /// fully read-only; this is preserved for future lock-down
    /// modes ("kids' iPad", school deployments).
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
    var isPhoneIdiom: Bool
    var isReadOnly: Bool { !canMutate }

    static let live = DeviceCapabilitiesProxy(
        canMutate:           DeviceCapabilities.canMutate,
        canDraw:             DeviceCapabilities.canDraw,
        canRecord:           DeviceCapabilities.canRecord,
        canEditMetadata:     DeviceCapabilities.canEditMetadata,
        canCreateInLibrary:  DeviceCapabilities.canCreateInLibrary,
        prefersTabletLayout: DeviceCapabilities.prefersTabletLayout,
        isPhoneIdiom:        DeviceCapabilities.isPhoneIdiom
    )

    /// Preview / test override that pins the device to read-only
    /// regardless of which simulator the preview's running on.
    static let readOnly = DeviceCapabilitiesProxy(
        canMutate: false, canDraw: false, canRecord: false,
        canEditMetadata: false, canCreateInLibrary: false,
        prefersTabletLayout: false, isPhoneIdiom: true
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

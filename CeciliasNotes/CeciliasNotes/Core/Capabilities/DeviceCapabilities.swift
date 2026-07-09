import SwiftUI
#if canImport(UIKit)
import UIKit
import GameController
#endif

/// Single source of truth for what the current device is allowed to
/// do.
///
/// **Two independent axes**:
///
/// 1. *Form factor* (`isPhoneIdiom`, `prefersTabletLayout`). Drives
///    layout — sidebar drawer vs inline, grid density, masthead
///    height. Decided purely by `UIDevice.userInterfaceIdiom` on iOS;
///    Mac always uses the tablet-style layout signal.
///
/// 2. *Capabilities* (`canMutate`, `canDraw`, `canRecord`, …). What
///    the user is allowed to *do*. These are independent of layout
///    so an iPhone can have a compact masthead AND let the user
///    rename a notebook, while still keeping the PencilKit canvas
///    disabled (no Apple Pencil on iPhone).
enum DeviceCapabilities {

    // MARK: - Form factor (layout signal, independent of capability)

    /// True on iPhone (compact-class device). Used by layouts
    /// that need to switch between iPad's side-by-side composition
    /// and iPhone's stacked / drawer composition. *Never* gates
    /// mutations — see `canMutate` for that.
    static var isPhoneIdiom: Bool {
#if canImport(UIKit)
        UIDevice.current.userInterfaceIdiom == .phone
#else
        false
#endif
    }

    /// True when the library + sidebar should lay out in their
    /// full tablet form. iPhone gets a single-column grid and a
    /// collapsed sidebar that surfaces via a drawer overlay.
    static var prefersTabletLayout: Bool { !isPhoneIdiom }

    /// True when the library grid exposes arrow-key focus + Return/Space
    /// shortcuts (iPad with external keyboard, Mac). Touch-only iPad
    /// must stay false — otherwise every card tap paints a persistent
    /// blue focus ring (`macGridFocusedNotebookId`) that reads as a
    /// stuck highlight when the user returns from the editor.
    static var supportsGridKeyboardNavigation: Bool {
#if os(macOS)
        true
#elseif canImport(UIKit)
        prefersTabletLayout && GCKeyboard.coalesced != nil
#else
        false
#endif
    }

    // MARK: - Capabilities (what the user is allowed to do)

    /// True when the device may create / edit / delete content.
    static var canMutate: Bool { true }

    /// True when the user can stroke ink on a page. iPhone and Mac
    /// have no Apple Pencil canvas; iPad: always true.
    static var canDraw: Bool {
#if os(iOS)
        !isPhoneIdiom
#else
        false
#endif
    }

    /// True when the user can start dictation / voice notes /
    /// lecture recordings.
    static var canRecord: Bool { true }

    /// True when the user can edit notebook metadata.
    static var canEditMetadata: Bool { true }

    /// True when the user can create new notebooks / subjects /
    /// quizzes from the library sidebar.
    static var canCreateInLibrary: Bool { true }

    /// Convenience inverse — reads better at call sites that
    /// branch on the read-only path.
    static var isReadOnly: Bool { !canMutate }
}

// MARK: - SwiftUI environment

private struct DeviceCapabilitiesKey: EnvironmentKey {
    static let defaultValue: DeviceCapabilitiesProxy = .live
}

/// Indirection over the static `DeviceCapabilities` namespace so
/// SwiftUI previews + tests can override the values.
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

    static let readOnly = DeviceCapabilitiesProxy(
        canMutate: false, canDraw: false, canRecord: false,
        canEditMetadata: false, canCreateInLibrary: false,
        prefersTabletLayout: false, isPhoneIdiom: true
    )
}

extension EnvironmentValues {
    var capabilities: DeviceCapabilitiesProxy {
        get { self[DeviceCapabilitiesKey.self] }
        set { self[DeviceCapabilitiesKey.self] = newValue }
    }
}

// MARK: - View modifier

extension View {
    @ViewBuilder
    func mutationOnly() -> some View {
        if DeviceCapabilities.canMutate { self }
    }

    func mutationDisabled(_ extra: Bool = false) -> some View {
        disabled(!DeviceCapabilities.canMutate || extra)
    }
}

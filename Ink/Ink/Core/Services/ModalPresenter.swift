import Combine
import SwiftUI

// MARK: - ModalPresenter
//
// Single SwiftUI presentation surface for the app. Phase 3b architecture
// goal — ONE `.sheet`, ONE `.fullScreenCover` attached to RootView,
// both driven by this presenter. Phase 5B wires the editor-internal
// sheets through this presenter to dodge SwiftUI's sheet-over-cover
// limitation: the editor itself is a `.fullScreenCover` from
// `LibraryView`, and SwiftUI silently fails the second sheet when an
// editor-internal `.sheet(...)` tries to present from underneath the
// cover. Routing through the presenter (which is mounted at RootView,
// above the cover) makes those internal sheets work reliably.
//
// Library-internal sheets that don't nest inside the editor cover
// (Settings, Move-to-folder, Tag filter, Ask My Notes, Recent
// Exports) keep their inline `.sheet` modifiers — they're top-level,
// don't collide with anything, and pulling them through a global
// presenter would just add indirection without solving a real
// problem. Phase 5B's scope is the collision class, not a
// stylistic uniformity pass.

@MainActor
final class ModalPresenter: ObservableObject {

    static let shared = ModalPresenter()
    private init() {}

    /// The modal currently being presented, if any. SwiftUI binds
    /// `RootView`'s single `.sheet(item:)` and `.fullScreenCover(item:)`
    /// to this property and the `Modal.kind` decides which attachment
    /// point gets used.
    @Published var active: Modal?

    /// Queue of modals waiting to present. Drained when `active` goes
    /// nil — the next one promotes in. Prevents the "second .sheet
    /// while another is still presenting" crash that SwiftUI emits as
    /// "Currently, only presenting a single sheet is supported" in
    /// the console (and silently fails the second).
    private var queue: [Modal] = []

    /// Enqueue a modal. If nothing's presenting, it shows immediately.
    /// If something IS presenting, it queues behind that modal and
    /// shows when the current modal dismisses.
    func present(_ modal: Modal) {
        guard active != nil else {
            active = modal
            return
        }
        queue.append(modal)
    }

    /// Dismiss the active modal. Promotes the next queued modal if any.
    /// Bound to RootView's `.sheet`/`.fullScreenCover` `onDismiss`
    /// callbacks so SwiftUI's user-driven dismiss also drains the queue.
    func dismiss() {
        let onDidDismiss = active?.onDidDismiss
        active = nil
        onDidDismiss?()
        if !queue.isEmpty {
            // One runloop tick so SwiftUI finishes its dismiss
            // animation before we present the next modal — back-to-back
            // presentations without the gap visibly stutter.
            let next = queue.removeFirst()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                self?.active = next
            }
        }
    }
}

// MARK: - Modal

/// Closure-based modal descriptor. Each call site constructs its own
/// SwiftUI view inside the `viewBuilder` closure — sidesteps the
/// enum-with-payload-and-closure problem (`@Sendable` / `Equatable` /
/// associated-value gymnastics) entirely. The presenter only needs
/// to know:
///
///   • A stable `id` so SwiftUI's `.sheet(item:)` / `.fullScreenCover(item:)`
///     can identify the modal across rebuilds.
///   • A `kind` (sheet vs full-screen cover) so the right attachment
///     point on RootView renders the modal.
///   • A `viewBuilder` closure that produces the SwiftUI content.
///
/// Equatable compares by `id` only — that's what SwiftUI uses to
/// decide "did the active modal change."
struct Modal: Identifiable, Equatable {

    let id: String
    let kind: PresentationKind
    let viewBuilder: () -> AnyView
    /// Fired by `ModalPresenter.dismiss()` after `active` is cleared.
    /// Callers use this to sync local @State / @Published booleans
    /// when the user dismisses via swipe (a path that doesn't go
    /// through the caller's explicit dismiss action).
    let onDidDismiss: (() -> Void)?

    enum PresentationKind { case sheet, cover }

    static func == (lhs: Modal, rhs: Modal) -> Bool { lhs.id == rhs.id }

    /// Convenience: a sheet with the given id and content.
    static func sheet<V: View>(
        id: String,
        onDidDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> V
    ) -> Modal {
        Modal(
            id: id,
            kind: .sheet,
            viewBuilder: { AnyView(content()) },
            onDidDismiss: onDidDismiss
        )
    }

    /// Convenience: a full-screen cover with the given id and content.
    static func cover<V: View>(
        id: String,
        onDidDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> V
    ) -> Modal {
        Modal(
            id: id,
            kind: .cover,
            viewBuilder: { AnyView(content()) },
            onDidDismiss: onDidDismiss
        )
    }
}

// MARK: - ModalHostView

/// Mounts the single `.sheet` and the single `.fullScreenCover`
/// attached to RootView. Reads `ModalPresenter.shared.active` and
/// derives a `Binding<Modal?>` for each kind so the kind that
/// doesn't match the active modal stays nil.
///
/// Usage in RootView:
///   `RootView { ... }.modifier(ModalHostView())`
struct ModalHostView: ViewModifier {

    @ObservedObject private var presenter = ModalPresenter.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: sheetBinding) { modal in
                modal.viewBuilder()
            }
            .fullScreenCover(item: coverBinding) { modal in
                modal.viewBuilder()
            }
    }

    // MARK: Bindings

    private var sheetBinding: Binding<Modal?> {
        Binding(
            get: {
                guard let m = presenter.active, m.kind == .sheet else { return nil }
                return m
            },
            set: { newValue in
                if newValue == nil { presenter.dismiss() }
            }
        )
    }

    private var coverBinding: Binding<Modal?> {
        Binding(
            get: {
                guard let m = presenter.active, m.kind == .cover else { return nil }
                return m
            },
            set: { newValue in
                if newValue == nil { presenter.dismiss() }
            }
        )
    }
}

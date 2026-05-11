/// ImagePickerBridge.swift
/// Cecilia's Notes
///
/// Singleton `ObservableObject` that lets a SwiftUI view living
/// inside a `.fullScreenCover`-presented destination (the editor)
/// trigger the image-import picker sheet from the root view's
/// level. Required because presenting a `.sheet` from inside a
/// `.fullScreenCover` on iPad is unreliable — the nested
/// presentation chain can collapse and dismiss the editor cover
/// when the inner picker resolves.
///
/// Flow:
///   1. `ImageAttachmentsView` / drag-drop / long-press call
///      `present(onPicked:)` with a closure capturing the editor's
///      view-model + the normalised tap location.
///   2. The published `pending` flips non-nil.
///   3. `LibraryView` (the root that owns the `.fullScreenCover`)
///      observes `pending` and presents `ImageImportPicker` at the
///      root level, ABOVE the cover.
///   4. Picker delivers → bridge invokes the captured closure →
///      bridge clears `pending`.

import Combine
import Foundation
import UIKit

@MainActor
final class ImagePickerBridge: ObservableObject {

    static let shared = ImagePickerBridge()

    /// Identifiable so `.sheet(item:)` can present off of it.
    /// `id` rolls on every new request — a fresh present after a
    /// cancel doesn't reuse the previous identity, so SwiftUI
    /// reliably re-presents the picker.
    struct PendingPick: Identifiable {
        let id: UUID = UUID()
        /// Invoked with the picked image + extension hint. The
        /// caller's closure typically routes the bytes through
        /// `EditorViewModel.commitImportedImage`.
        let onPicked: (UIImage, String) -> Void
    }

    @Published var pending: PendingPick?

    /// Show the picker. The provided closure fires once on
    /// successful pick. On cancel the bridge just clears `pending`
    /// — no callback fires for cancellation.
    func present(onPicked: @escaping (UIImage, String) -> Void) {
        pending = PendingPick(onPicked: { [weak self] image, ext in
            onPicked(image, ext)
            self?.pending = nil
        })
    }

    /// Explicit cancel — called by the picker's `onCancel` path.
    /// Clears state without invoking the success closure.
    func cancel() {
        pending = nil
    }

    private init() {}
}

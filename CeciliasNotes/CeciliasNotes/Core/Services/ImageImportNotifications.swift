/// ImageImportNotifications.swift
/// Cecilia's Notes
///
/// Shared types + notification names for the image-import flow's
/// cross-view-model communication. The editor (inside the
/// `.fullScreenCover` destination) signals intent via these
/// notifications; the library (the cover's host) owns the
/// `.sheet(item:)` presentation and the picker's lifecycle.
///
/// Why notifications rather than a direct binding: the picker
/// must be presented from above the navigation destination (the
/// editor's cover), so its state has to live on the library
/// view-model. The editor view-model doesn't import the library
/// view-model — keeping the dependency direction one-way avoids
/// retain cycles and a tangled MVVM graph. Notifications are
/// the SwiftUI-idiomatic decoupling channel for this shape of
/// problem.

import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - PendingImageImport

/// Identifiable request driving `.sheet(item:)` from the library
/// root level. Carries the normalised tap location forward so the
/// completion callback can echo it back to the editor for
/// placement.
struct PendingImageImport: Identifiable, Equatable {
    let id: UUID = UUID()
    let normalizedX: Double
    let normalizedY: Double
}

// MARK: - Notification names

extension Notification.Name {
    /// Posted by the editor when the user has triggered an image
    /// import (canvas tap with the image tool, long-press
    /// "Insert Image", drag-drop target, or the toolbar's
    /// centre-import action). `userInfo`:
    ///   • `"normalizedX": Double` — 0–1 page coord, top-left origin
    ///   • `"normalizedY": Double` — 0–1 page coord, top-left origin
    /// `LibraryViewModel` observes and sets `pendingImageImport`.
    static let imageImportRequested = Notification.Name("imageImportRequested")

    /// Posted by the library's picker callback after the user
    /// successfully picks an image. `userInfo`:
    ///   • `"image": UIImage`
    ///   • `"ext": String` ("jpg" / "png" / "heic")
    ///   • `"normalizedX": Double`, `"normalizedY": Double`
    /// The editor observes and calls `commitImportedImage`.
    static let imageImportCompleted = Notification.Name("imageImportCompleted")

    /// Posted when the user dismisses the source-choice dialog or
    /// a sub-picker without selecting. `LibraryViewModel` clears
    /// `pendingImageImport`. No `userInfo`.
    static let imageImportCancelled = Notification.Name("imageImportCancelled")
}

// MARK: - userInfo helpers

enum ImageImportUserInfoKey {
    static let image       = "image"
    /// Optional. `[UIImage]` — every image the user picked when the
    /// picker allows multi-select. When present, the editor commits
    /// each one (cascaded slightly so they don't stack perfectly);
    /// `image` stays populated with the first for any observer that
    /// only handles one.
    static let images      = "images"
    static let ext         = "ext"
    static let normalizedX = "normalizedX"
    static let normalizedY = "normalizedY"
    /// Optional. `String` raw value of `ImageImportSource`. When
    /// absent, the library presents the photo-library picker (back-
    /// compat with the existing canvas-tap / drag-drop / toolbar
    /// paths). Set to `.camera` by the toolbar's long-press gesture
    /// to route through `UIImagePickerController(.camera)` instead.
    static let source      = "source"
}

/// Which sub-picker the library should present in response to an
/// `imageImportRequested` notification. Defaults to `.photos`.
enum ImageImportSource: String {
    case photos
    case camera
}

// MARK: - Image tool variant persistence

/// Persisted picker preference for the editor's image tool. The
/// floating toolbar's image button uses the stored variant for its
/// tap action and renders the matching SF Symbol so the user can see
/// which picker the next tap will open. Long-press on the image
/// button shows the variant picker that writes this value.
enum ImageToolVariant: String, CaseIterable {
    case photoLibrary
    case camera

    /// Maps to the existing `ImageImportSource` notification payload
    /// so the library's picker presenter doesn't need a parallel
    /// enum.
    var importSource: ImageImportSource {
        switch self {
        case .photoLibrary: return .photos
        case .camera:       return .camera
        }
    }

    var systemImage: String {
        switch self {
        case .photoLibrary: return "photo.on.rectangle"
        case .camera:       return "camera"
        }
    }

    var displayName: String {
        switch self {
        case .photoLibrary: return "Photo library"
        case .camera:       return "Camera"
        }
    }
}

/// UserDefaults-backed store for the image-tool variant. Single-value
/// store — kept in this file so the variant enum and its persistence
/// live next to the notification types they bridge.
enum ImageToolVariantStore {
    private static let key = "tool.image.variant"

    static var current: ImageToolVariant {
        get {
            guard let raw = UserDefaults.standard.string(forKey: key),
                  let variant = ImageToolVariant(rawValue: raw)
            else { return .photoLibrary }
            return variant
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .imageToolVariantChanged, object: nil)
        }
    }
}

extension Notification.Name {
    /// Posted whenever `ImageToolVariantStore.current` is written. The
    /// floating toolbar listens so its glyph updates immediately when
    /// the variant picker writes a new value.
    static let imageToolVariantChanged = Notification.Name("imageToolVariantChanged")
}

/// ImagePickerBridge.swift
/// Cecilia's Notes
///
/// Retired. Picker presentation is now driven by
/// `LibraryViewModel.pendingImageImport` (root-level state) with
/// cross-view-model communication via `NotificationCenter`. See
/// `Notification.Name.imageImportRequested` /
/// `.imageImportCompleted` / `.imageImportCancelled` for the
/// signalling protocol.
///
/// File kept on disk so Xcode target membership doesn't need to
/// change — it contributes no symbols now.

import Foundation

//
//  InkWidget.swift
//  InkWidget
//
//  Holds the cross-target wire format used by `WidgetDataWriter` in
//  the main app and by every widget in this bundle to read recents
//  from the App Group's JSON snapshot. The legacy `InkWidget` /
//  `QuickCaptureWidget` configurations that used to live here were
//  retired during the design-language refresh — see
//  `NewNoteWidget.swift` for the current widget set.
//

import WidgetKit
import SwiftUI

// MARK: - Shared model (mirrors WidgetDataWriter.NotebookSummary in the main target)

struct NotebookSummary: Codable, Identifiable, Sendable, Hashable {
    let id:            UUID
    let title:         String
    let coverColorHex: String
    let coverTexture:  String  // CoverTexture.rawValue
    let pageCount:     Int
    let updatedAt:     Date
}

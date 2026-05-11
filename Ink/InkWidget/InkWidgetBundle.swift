//
//  InkWidgetBundle.swift
//  InkWidget
//
//  Registers every widget the extension ships. The set was rebuilt
//  during the Cecilia's Notes design-language refresh — the legacy
//  `InkWidget` and `QuickCaptureWidget` configurations are gone; see
//  `NewNoteWidget.swift` for the canonical five.
//

import WidgetKit
import SwiftUI

@main
struct InkWidgetBundle: WidgetBundle {
    var body: some Widget {
        // Home Screen
        HomeSmallNewNoteWidget()
        HomeMediumRecentsWidget()

        // Lock Screen
        LockCircularNewNoteWidget()
        LockRectangularLastNotebookWidget()
        LockInlineRecentWidget()
    }
}

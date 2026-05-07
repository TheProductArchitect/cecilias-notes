import WidgetKit
import SwiftUI

// MARK: - InkWidgetBundle
//
// Required Xcode setup:
//   1. Add a new "Widget Extension" target (no Configuration Intent — App Intents added separately)
//      named "InkWidget", bundle identifier {appBundle}.InkWidget.
//   2. Both main app + InkWidget targets enable the same App Group
//      (default: group.com.ink.app — change `WidgetDataWriter.appGroup` to match yours).
//   3. Add this file (and the three files alongside it) to the InkWidget target only.
//   4. Add WidgetDataWriter.swift's `NotebookSummary` to the InkWidget target as well
//      (Target Membership ✔ on the file). Keep WidgetDataWriter.swift itself in the main
//      app — the widget only needs the model + `read()` static.

@main
struct InkWidgetBundle: WidgetBundle {
    var body: some Widget {
        LastOpenedNotebookWidget()
        RecentNotebooksWidget()
    }
}

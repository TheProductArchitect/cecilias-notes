//
//  CeciliasNotesWidgetLiveActivity.swift
//  CeciliasNotesWidget
//
//  Created by Venu gopinath Nukavarapu on 5/7/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct CeciliasNotesWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct CeciliasNotesWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CeciliasNotesWidgetAttributes.self) { context in
            // Lock screen/banner UI goes here
            VStack {
                Text("Hello \(context.state.emoji)")
            }
            .activityBackgroundTint(Color.cyan)
            .activitySystemActionForegroundColor(Color.black)

        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded UI goes here.  Compose the expanded UI through
                // various regions, like leading/trailing/center/bottom
                DynamicIslandExpandedRegion(.leading) {
                    Text("Leading")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("Trailing")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Bottom \(context.state.emoji)")
                    // more content
                }
            } compactLeading: {
                Text("L")
            } compactTrailing: {
                Text("T \(context.state.emoji)")
            } minimal: {
                Text(context.state.emoji)
            }
            .widgetURL(URL(string: "http://www.apple.com"))
            .keylineTint(Color.red)
        }
    }
}

extension CeciliasNotesWidgetAttributes {
    fileprivate static var preview: CeciliasNotesWidgetAttributes {
        CeciliasNotesWidgetAttributes(name: "World")
    }
}

extension CeciliasNotesWidgetAttributes.ContentState {
    fileprivate static var smiley: CeciliasNotesWidgetAttributes.ContentState {
        CeciliasNotesWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: CeciliasNotesWidgetAttributes.ContentState {
         CeciliasNotesWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: CeciliasNotesWidgetAttributes.preview) {
   CeciliasNotesWidgetLiveActivity()
} contentStates: {
    CeciliasNotesWidgetAttributes.ContentState.smiley
    CeciliasNotesWidgetAttributes.ContentState.starEyes
}

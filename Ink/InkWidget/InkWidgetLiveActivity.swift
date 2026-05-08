//
//  InkWidgetLiveActivity.swift
//  InkWidget
//
//  Created by Venu gopinath Nukavarapu on 5/7/26.
//

import ActivityKit
import WidgetKit
import SwiftUI

struct InkWidgetAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Dynamic stateful properties about your activity go here!
        var emoji: String
    }

    // Fixed non-changing properties about your activity go here!
    var name: String
}

struct InkWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: InkWidgetAttributes.self) { context in
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

extension InkWidgetAttributes {
    fileprivate static var preview: InkWidgetAttributes {
        InkWidgetAttributes(name: "World")
    }
}

extension InkWidgetAttributes.ContentState {
    fileprivate static var smiley: InkWidgetAttributes.ContentState {
        InkWidgetAttributes.ContentState(emoji: "😀")
     }
     
     fileprivate static var starEyes: InkWidgetAttributes.ContentState {
         InkWidgetAttributes.ContentState(emoji: "🤩")
     }
}

#Preview("Notification", as: .content, using: InkWidgetAttributes.preview) {
   InkWidgetLiveActivity()
} contentStates: {
    InkWidgetAttributes.ContentState.smiley
    InkWidgetAttributes.ContentState.starEyes
}

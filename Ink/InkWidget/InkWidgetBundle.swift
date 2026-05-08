//
//  InkWidgetBundle.swift
//  InkWidget
//
//  Created by Venu gopinath Nukavarapu on 5/7/26.
//

import WidgetKit
import SwiftUI

@main
struct InkWidgetBundle: WidgetBundle {
    var body: some Widget {
        InkWidget()
        QuickCaptureWidget()
    }
}

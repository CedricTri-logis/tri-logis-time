//
//  ShiftActivityWidgetBundle.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import WidgetKit
import SwiftUI

@main
struct ShiftActivityWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            ShiftActivityWidgetLiveActivity()
        }
    }
}

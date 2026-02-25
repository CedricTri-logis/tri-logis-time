//
//  LiveActivitiesAppAttributes.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import Foundation

/// ActivityAttributes for shift Live Activity.
/// Must match the Runner target's ShiftActivityAttributes exactly.
/// Data passes directly via ContentState — no UserDefaults needed.
struct ShiftActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var clockedInAtMs: Int
        var status: String
    }
}

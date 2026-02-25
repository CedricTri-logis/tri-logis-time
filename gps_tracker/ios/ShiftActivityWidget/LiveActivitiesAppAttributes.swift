//
//  LiveActivitiesAppAttributes.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import Foundation

/// ActivityAttributes required by the `live_activities` Flutter package.
/// The package maps Dart `Map<String, dynamic>` values to `ContentState` properties
/// via UserDefaults (App Group).
///
/// The name `LiveActivitiesAppAttributes` is required by the package convention.
struct LiveActivitiesAppAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        // Epoch milliseconds of clock-in time
        var clockedInAtMs: Int?
        // "active" or "gps_lost"
        var status: String?
    }
}

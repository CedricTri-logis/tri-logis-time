//
//  LiveActivitiesAppAttributes.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import Foundation

/// ActivityAttributes required by the `live_activities` Flutter package.
///
/// IMPORTANT: This struct MUST mirror the one inside SwiftLiveActivitiesPlugin.swift.
/// The package stores Dart data in UserDefaults (App Group), NOT in ContentState.
/// ContentState only carries the appGroupId so the widget knows which UserDefaults to read.
struct LiveActivitiesAppAttributes: ActivityAttributes, Identifiable {
    public typealias LiveDeliveryData = ContentState

    public struct ContentState: Codable, Hashable {
        var appGroupId: String
    }

    var id = UUID()
}

extension LiveActivitiesAppAttributes {
    /// Generate a prefixed key to read data from UserDefaults.
    /// The plugin stores each Dart map entry as: "{activityUUID}_{dartKey}"
    func prefixedKey(_ key: String) -> String {
        return "\(id)_\(key)"
    }
}

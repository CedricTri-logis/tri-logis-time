//
//  ShiftActivityWidgetLiveActivity.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import WidgetKit
import SwiftUI

/// Shared UserDefaults for reading data written by the live_activities Flutter plugin.
let sharedDefault = UserDefaults(suiteName: "group.com.cedriclajoie.gpstracker.liveactivities")!

@available(iOSApplicationExtension 16.1, *)
struct ShiftActivityWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveActivitiesAppAttributes.self) { context in
            // Lock Screen banner
            lockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.75))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "clock.fill")
                        .foregroundColor(.blue)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    gpsStatusIcon(context: context)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    if let clockedInAt = clockedInDate(from: context) {
                        Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                            .font(.title2)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundColor(.white)
                    } else {
                        Text("Quart actif")
                            .font(.headline)
                            .foregroundColor(.white)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text("Quart actif")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } compactLeading: {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
            } compactTrailing: {
                if let clockedInAt = clockedInDate(from: context) {
                    Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                        .monospacedDigit()
                        .font(.caption)
                        .frame(width: 48)
                } else {
                    Image(systemName: "location.fill")
                        .foregroundColor(.green)
                }
            } minimal: {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<LiveActivitiesAppAttributes>) -> some View {
        HStack(spacing: 12) {
            // Clock icon
            Image(systemName: "clock.fill")
                .font(.title2)
                .foregroundColor(.blue)

            VStack(alignment: .leading, spacing: 2) {
                Text("Quart actif")
                    .font(.headline)
                    .foregroundColor(.white)

                if let clockedInAt = clockedInDate(from: context) {
                    HStack(spacing: 4) {
                        Text("Depuis")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Text(clockedInAt, style: .time)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }
            }

            Spacer()

            // Timer
            if let clockedInAt = clockedInDate(from: context) {
                Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundColor(.white)
            }

            // GPS status indicator
            gpsStatusIcon(context: context)
                .font(.title3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    /// Read clockedInAtMs from UserDefaults (written by the live_activities Flutter plugin).
    private func clockedInDate(from context: ActivityViewContext<LiveActivitiesAppAttributes>) -> Date? {
        let ms = sharedDefault.integer(forKey: context.attributes.prefixedKey("clockedInAtMs"))
        guard ms > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// Read GPS status from UserDefaults.
    @ViewBuilder
    private func gpsStatusIcon(context: ActivityViewContext<LiveActivitiesAppAttributes>) -> some View {
        let status = sharedDefault.string(forKey: context.attributes.prefixedKey("status")) ?? "active"
        if status == "gps_lost" {
            Image(systemName: "location.slash.fill")
                .foregroundColor(.orange)
        } else {
            Image(systemName: "location.fill")
                .foregroundColor(.green)
        }
    }
}

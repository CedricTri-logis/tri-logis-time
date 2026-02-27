//
//  ShiftActivityWidgetLiveActivity.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import WidgetKit
import SwiftUI

@available(iOSApplicationExtension 16.1, *)
struct ShiftActivityWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftActivityAttributes.self) { context in
            // Lock Screen banner
            lockScreenView(context: context)
                .widgetURL(URL(string: "ca.trilogis.gpstracker://home"))
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
                    gpsStatusIcon(status: context.state.status)
                        .font(.title2)
                }
                DynamicIslandExpandedRegion(.center) {
                    let clockedInAt = clockedInDate(ms: context.state.clockedInAtMs)
                    Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let sessionLocation = context.state.sessionLocation {
                        HStack(spacing: 6) {
                            Image(systemName: sessionIcon(for: context.state.sessionType))
                                .font(.caption)
                                .foregroundColor(.blue)
                            Text(sessionLocation)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                            Spacer()
                            Link(destination: URL(string: "ca.trilogis.gpstracker://home")!) {
                                Text("Voir")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.blue)
                            }
                        }
                    } else {
                        Text("Quart actif")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
            } compactTrailing: {
                let clockedInAt = clockedInDate(ms: context.state.clockedInAtMs)
                Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 48)
            } minimal: {
                Image(systemName: "clock.fill")
                    .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<ShiftActivityAttributes>) -> some View {
        let clockedInAt = clockedInDate(ms: context.state.clockedInAtMs)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Clock icon
                Image(systemName: "clock.fill")
                    .font(.title2)
                    .foregroundColor(.blue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quart actif")
                        .font(.headline)
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        Text("Depuis")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                        Text(clockedInAt, style: .time)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.7))
                    }
                }

                Spacer()

                // Timer
                Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                    .font(.title)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundColor(.white)

                // GPS status indicator
                gpsStatusIcon(status: context.state.status)
                    .font(.title3)
            }

            // Session info row (when active)
            if let sessionLocation = context.state.sessionLocation {
                HStack(spacing: 6) {
                    Image(systemName: sessionIcon(for: context.state.sessionType))
                        .font(.caption)
                        .foregroundColor(.blue)
                    Text(sessionLocation)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer()
                    Text("Voir \u{203A}")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.blue)
                }
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Helpers

    private func clockedInDate(ms: Int) -> Date {
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    private func sessionIcon(for sessionType: String?) -> String {
        if sessionType == "maintenance" {
            return "wrench.fill"
        }
        return "bubbles.and.sparkles.fill"
    }

    @ViewBuilder
    private func gpsStatusIcon(status: String) -> some View {
        if status == "gps_lost" {
            Image(systemName: "location.slash.fill")
                .foregroundColor(.orange)
        } else {
            Image(systemName: "location.fill")
                .foregroundColor(.green)
        }
    }
}

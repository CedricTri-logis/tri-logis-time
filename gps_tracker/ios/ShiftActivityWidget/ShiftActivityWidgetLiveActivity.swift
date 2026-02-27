//
//  ShiftActivityWidgetLiveActivity.swift
//  ShiftActivityWidget
//
//  Created by Cedric on 2026-02-25.
//

import ActivityKit
import WidgetKit
import SwiftUI

// Tri-Logis brand color — Pantone 200 (#D11848)
private let brandRed = Color(red: 209/255, green: 24/255, blue: 72/255)

@available(iOSApplicationExtension 16.1, *)
struct ShiftActivityWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShiftActivityAttributes.self) { context in
            // Lock Screen banner
            lockScreenView(context: context)
                .widgetURL(URL(string: "ca.trilogis.gpstracker://home"))
                .activityBackgroundTint(Color.black.opacity(0.8))
                .activitySystemActionForegroundColor(Color.white)
        } dynamicIsland: { context in
            DynamicIsland {
                // Expanded regions
                DynamicIslandExpandedRegion(.leading) {
                    Image("LogoSymbol")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 32, height: 16)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    gpsStatusIcon(status: context.state.status)
                        .font(.title3)
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
                                .foregroundColor(brandRed)
                            Text(sessionLocation)
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.9))
                                .lineLimit(1)
                            if let sessionMs = context.state.sessionStartedAtMs {
                                let sessionStart = Date(timeIntervalSince1970: Double(sessionMs) / 1000.0)
                                Text(timerInterval: sessionStart...Date.distantFuture, countsDown: false)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundColor(brandRed)
                            }
                            Spacer(minLength: 0)
                            Link(destination: URL(string: "ca.trilogis.gpstracker://home")!) {
                                Text("Voir")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(brandRed)
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
                    .foregroundColor(brandRed)
            } compactTrailing: {
                let clockedInAt = clockedInDate(ms: context.state.clockedInAtMs)
                Text(timerInterval: clockedInAt...Date.distantFuture, countsDown: false)
                    .monospacedDigit()
                    .font(.caption)
                    .frame(width: 48)
            } minimal: {
                Image(systemName: "clock.fill")
                    .foregroundColor(brandRed)
            }
        }
    }

    // MARK: - Lock Screen View

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<ShiftActivityAttributes>) -> some View {
        let clockedInAt = clockedInDate(ms: context.state.clockedInAtMs)

        VStack(spacing: 8) {
            // Main row: logo + info + timer + GPS
            HStack(spacing: 12) {
                // Tri-Logis logo mark
                Image("LogoSymbol")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 36, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Quart actif")
                        .font(.headline)
                        .foregroundColor(.white)

                    HStack(spacing: 4) {
                        Text("Depuis")
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                        Text(clockedInAt, style: .time)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.6))
                    }
                }

                Spacer()

                // Shift timer
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
                Divider()
                    .background(Color.white.opacity(0.2))

                HStack(spacing: 6) {
                    Image(systemName: sessionIcon(for: context.state.sessionType))
                        .font(.subheadline)
                        .foregroundColor(brandRed)
                    Text(sessionLocation)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    // Session duration timer
                    if let sessionMs = context.state.sessionStartedAtMs {
                        let sessionStart = Date(timeIntervalSince1970: Double(sessionMs) / 1000.0)
                        Text(timerInterval: sessionStart...Date.distantFuture, countsDown: false)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .monospacedDigit()
                            .foregroundColor(brandRed)
                    }
                    Text("Voir \u{203A}")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.5))
                }
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

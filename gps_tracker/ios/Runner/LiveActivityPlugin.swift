import Flutter
import UIKit

// Import ActivityKit only where available
#if canImport(ActivityKit)
import ActivityKit
#endif

/// ActivityAttributes for shift Live Activity.
/// Defined at Runner module top-level so ActivityKit can match it
/// with the Widget Extension's identical definition.
///
/// Data passes directly via ContentState — no UserDefaults needed.
@available(iOS 16.1, *)
struct ShiftActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var clockedInAtMs: Int
        var status: String
        var sessionType: String?
        var sessionLocation: String?
        var sessionStartedAtMs: Int?
    }
}

/// Native Flutter plugin for iOS Live Activities.
/// Bypasses the `live_activities` package to avoid nested-type matching issues.
class LiveActivityPlugin: NSObject, FlutterPlugin {
    private var activitiesToEndOnKill: [String] = []

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "shift_live_activity",
            binaryMessenger: registrar.messenger()
        )
        let instance = LiveActivityPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        registrar.addApplicationDelegate(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "areActivitiesEnabled":
            handleAreActivitiesEnabled(result: result)
        case "createActivity":
            handleCreateActivity(call: call, result: result)
        case "updateActivity":
            handleUpdateActivity(call: call, result: result)
        case "endActivity":
            handleEndActivity(call: call, result: result)
        case "endAllActivities":
            handleEndAllActivities(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Method Handlers

    private func handleAreActivitiesEnabled(result: @escaping FlutterResult) {
        if #available(iOS 16.1, *) {
            result(ActivityAuthorizationInfo().areActivitiesEnabled)
        } else {
            result(false)
        }
    }

    private func handleCreateActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 16.1, *) else {
            result(FlutterError(code: "UNSUPPORTED", message: "Live Activities require iOS 16.1+", details: nil))
            return
        }

        guard let args = call.arguments as? [String: Any],
              let clockedInAtMs = args["clockedInAtMs"] as? Int,
              let status = args["status"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing clockedInAtMs or status", details: nil))
            return
        }

        let removeWhenAppIsKilled = args["removeWhenAppIsKilled"] as? Bool ?? true
        let sessionType = args["sessionType"] as? String
        let sessionLocation = args["sessionLocation"] as? String
        let sessionStartedAtMs = args["sessionStartedAtMs"] as? Int

        let attributes = ShiftActivityAttributes()
        let contentState = ShiftActivityAttributes.ContentState(
            clockedInAtMs: clockedInAtMs,
            status: status,
            sessionType: sessionType,
            sessionLocation: sessionLocation,
            sessionStartedAtMs: sessionStartedAtMs
        )

        do {
            let activity: Activity<ShiftActivityAttributes>

            if #available(iOS 16.2, *) {
                let content = ActivityContent(state: contentState, staleDate: nil)
                activity = try Activity.request(
                    attributes: attributes,
                    content: content,
                    pushType: nil
                )
            } else {
                activity = try Activity.request(
                    attributes: attributes,
                    contentState: contentState,
                    pushType: nil
                )
            }

            if removeWhenAppIsKilled {
                activitiesToEndOnKill.append(activity.id)
            }

            result(activity.id)
        } catch {
            result(FlutterError(
                code: "LIVE_ACTIVITY_ERROR",
                message: "Failed to create activity",
                details: error.localizedDescription
            ))
        }
    }

    private func handleUpdateActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 16.1, *) else {
            result(nil)
            return
        }

        guard let args = call.arguments as? [String: Any],
              let activityId = args["activityId"] as? String,
              let clockedInAtMs = args["clockedInAtMs"] as? Int,
              let status = args["status"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing activityId, clockedInAtMs, or status", details: nil))
            return
        }

        let sessionType = args["sessionType"] as? String
        let sessionLocation = args["sessionLocation"] as? String
        let sessionStartedAtMs = args["sessionStartedAtMs"] as? Int

        let newState = ShiftActivityAttributes.ContentState(
            clockedInAtMs: clockedInAtMs,
            status: status,
            sessionType: sessionType,
            sessionLocation: sessionLocation,
            sessionStartedAtMs: sessionStartedAtMs
        )

        Task {
            for activity in Activity<ShiftActivityAttributes>.activities {
                if activity.id == activityId {
                    await activity.update(using: newState)
                    break
                }
            }
            result(nil)
        }
    }

    private func handleEndActivity(call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard #available(iOS 16.1, *) else {
            result(nil)
            return
        }

        guard let args = call.arguments as? [String: Any],
              let activityId = args["activityId"] as? String else {
            result(FlutterError(code: "INVALID_ARGS", message: "Missing activityId", details: nil))
            return
        }

        activitiesToEndOnKill.removeAll { $0 == activityId }

        Task {
            for activity in Activity<ShiftActivityAttributes>.activities {
                if activity.id == activityId {
                    await activity.end(dismissalPolicy: .immediate)
                    break
                }
            }
            result(nil)
        }
    }

    private func handleEndAllActivities(result: @escaping FlutterResult) {
        guard #available(iOS 16.1, *) else {
            result(nil)
            return
        }

        activitiesToEndOnKill.removeAll()

        Task {
            for activity in Activity<ShiftActivityAttributes>.activities {
                await activity.end(dismissalPolicy: .immediate)
            }
            result(nil)
        }
    }

    // MARK: - App Lifecycle

    func applicationWillTerminate(_ application: UIApplication) {
        if #available(iOS 16.1, *) {
            let idsToEnd = activitiesToEndOnKill
            Task {
                for activity in Activity<ShiftActivityAttributes>.activities {
                    if idsToEnd.contains(activity.id) {
                        await activity.end(dismissalPolicy: .immediate)
                    }
                }
            }
        }
    }
}

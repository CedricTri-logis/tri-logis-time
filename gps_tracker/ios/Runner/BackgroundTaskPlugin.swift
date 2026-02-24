import Flutter
import UIKit
import CoreLocation

/// Native iOS plugin for background execution management.
///
/// Exposes two key APIs to Flutter:
/// 1. CLBackgroundActivitySession (iOS 17+) — declares legitimate continuous
///    background location activity, showing the blue location indicator.
/// 2. UIApplication.beginBackgroundTask — requests ~30s of additional execution
///    time during the foreground-to-background transition.
///
/// Also provides thermal state monitoring via ProcessInfo.
class BackgroundTaskPlugin: NSObject, FlutterPlugin {
    private var executionChannel: FlutterMethodChannel?
    private var thermalChannel: FlutterMethodChannel?

    // CLBackgroundActivitySession (iOS 17+) — must hold strong reference
    private var backgroundSession: Any?

    // Background task for foreground-to-background transition protection
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    static func register(with registrar: FlutterPluginRegistrar) {
        let instance = BackgroundTaskPlugin()

        // Background execution method channel
        let executionChannel = FlutterMethodChannel(
            name: "gps_tracker/background_execution",
            binaryMessenger: registrar.messenger()
        )
        instance.executionChannel = executionChannel
        registrar.addMethodCallDelegate(instance, channel: executionChannel)

        // Thermal state method channel
        let thermalChannel = FlutterMethodChannel(
            name: "gps_tracker/thermal",
            binaryMessenger: registrar.messenger()
        )
        instance.thermalChannel = thermalChannel

        // Register thermal state observer
        NotificationCenter.default.addObserver(
            instance,
            selector: #selector(instance.thermalStateDidChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        // --- Background Execution ---
        case "startBackgroundSession":
            startBackgroundSession(result: result)
        case "stopBackgroundSession":
            stopBackgroundSession(result: result)
        case "isBackgroundSessionActive":
            result(backgroundSession != nil)
        case "beginBackgroundTask":
            let args = call.arguments as? [String: Any]
            let name = args?["name"] as? String ?? "gps_tracker_background_task"
            beginBackgroundTask(name: name, result: result)
        case "endBackgroundTask":
            endBackgroundTask(result: result)

        // --- Thermal State ---
        case "getThermalState":
            result(ProcessInfo.processInfo.thermalState.rawValue)

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - CLBackgroundActivitySession

    private func startBackgroundSession(result: @escaping FlutterResult) {
        // Already active — no-op
        if backgroundSession != nil {
            result(true)
            return
        }

        if #available(iOS 17.0, *) {
            backgroundSession = CLBackgroundActivitySession()
            NSLog("[BackgroundTaskPlugin] CLBackgroundActivitySession started (iOS 17+)")
        } else {
            NSLog("[BackgroundTaskPlugin] CLBackgroundActivitySession not available (iOS < 17), no-op")
        }
        result(true)
    }

    private func stopBackgroundSession(result: @escaping FlutterResult) {
        if #available(iOS 17.0, *) {
            if let session = backgroundSession as? CLBackgroundActivitySession {
                session.invalidate()
                NSLog("[BackgroundTaskPlugin] CLBackgroundActivitySession invalidated")
            }
        }
        backgroundSession = nil
        result(true)
    }

    // MARK: - beginBackgroundTask

    private func beginBackgroundTask(name: String, result: @escaping FlutterResult) {
        // Already have an active task — no-op
        if backgroundTaskID != .invalid {
            result(true)
            return
        }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Expiration handler — MUST call endBackgroundTask
            guard let self = self else { return }
            NSLog("[BackgroundTaskPlugin] Background task expired, ending task")
            UIApplication.shared.endBackgroundTask(self.backgroundTaskID)
            self.backgroundTaskID = .invalid

            // Notify Flutter
            self.executionChannel?.invokeMethod("onBackgroundTaskExpired", arguments: nil)
        }
        NSLog("[BackgroundTaskPlugin] beginBackgroundTask started (id: \(backgroundTaskID.rawValue))")
        result(true)
    }

    private func endBackgroundTask(result: @escaping FlutterResult) {
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            NSLog("[BackgroundTaskPlugin] endBackgroundTask (id: \(backgroundTaskID.rawValue))")
            backgroundTaskID = .invalid
        }
        result(true)
    }

    // MARK: - Thermal State

    @objc private func thermalStateDidChange() {
        let state = ProcessInfo.processInfo.thermalState.rawValue
        NSLog("[BackgroundTaskPlugin] Thermal state changed: \(state)")
        thermalChannel?.invokeMethod("onThermalStateChanged", arguments: state)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

import BackgroundTasks
import Flutter

/// iOS BGAppRefreshTask plugin for stationary tracking recovery.
///
/// When iOS kills the app and the employee is stationary (no SLC trigger),
/// this is the only mechanism that can relaunch the app to restart tracking.
/// iOS schedules the task based on app usage patterns (typically 15-30 min).
///
/// The handler is intentionally minimal (UserDefaults reads only) to avoid
/// CPU spikes that could cause iOS to deprioritize future scheduling.
class BackgroundAppRefreshPlugin: NSObject, FlutterPlugin {
    static let taskIdentifier = "ca.trilogis.gpstracker.trackingRefresh"

    /// flutter_foreground_task stores shift_id under this UserDefaults key.
    private static let fftShiftIdKey =
        "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"

    /// Breadcrumb log key — synced by Flutter on next app resume.
    private static let breadcrumbsKey = "bg_refresh_breadcrumbs"

    // MARK: - Registration

    /// Must be called in AppDelegate.didFinishLaunchingWithOptions BEFORE super.
    /// BGTaskScheduler.register requires this timing.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { task in
            handleAppRefresh(task: task as! BGAppRefreshTask)
        }

        // If there's an active shift, schedule immediately
        scheduleIfNeeded()
    }

    /// FlutterPlugin conformance — MethodChannel for Dart-side schedule/cancel.
    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "gps_tracker/bg_app_refresh",
            binaryMessenger: registrar.messenger()
        )
        let instance = BackgroundAppRefreshPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "schedule":
            BackgroundAppRefreshPlugin.scheduleIfNeeded()
            result(true)
        case "cancel":
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: BackgroundAppRefreshPlugin.taskIdentifier)
            NSLog("[BGAppRefresh] Cancelled")
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Task handling

    private static func handleAppRefresh(task: BGAppRefreshTask) {
        // Re-schedule for next occurrence (BGAppRefreshTask is one-shot)
        scheduleIfNeeded()

        let shiftId =
            UserDefaults.standard.string(forKey: fftShiftIdKey) ?? ""

        // Write breadcrumb for diagnostic sync
        writeBreadcrumb(shiftId: shiftId)

        if shiftId.isEmpty {
            NSLog("[BGAppRefresh] No active shift — no-op")
        } else {
            NSLog(
                "[BGAppRefresh] Active shift \(shiftId) — app launched, Flutter recovery will handle restart"
            )
            // The app being launched is enough: main() → _refreshServiceState()
            // detects dead service + active shift → restarts tracking.
        }

        task.setTaskCompleted(success: true)
    }

    // MARK: - Scheduling

    static func scheduleIfNeeded() {
        let shiftId = UserDefaults.standard.string(forKey: fftShiftIdKey)
        guard let shiftId, !shiftId.isEmpty else {
            BGTaskScheduler.shared.cancel(
                taskRequestWithIdentifier: taskIdentifier)
            return
        }

        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        // Ask iOS to run in ~5 min. iOS may delay longer based on usage patterns.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
            NSLog(
                "[BGAppRefresh] Scheduled next refresh in ~5min for shift \(shiftId)"
            )
        } catch {
            NSLog("[BGAppRefresh] Failed to schedule: \(error)")
        }
    }

    // MARK: - Breadcrumbs

    private static func writeBreadcrumb(shiftId: String) {
        let formatter = ISO8601DateFormatter()
        let timestamp = formatter.string(from: Date())
        let status = shiftId.isEmpty ? "no_shift" : "active"

        var breadcrumbs =
            UserDefaults.standard.stringArray(forKey: breadcrumbsKey) ?? []
        breadcrumbs.append("\(timestamp)|bg_refresh|\(status)|\(shiftId)")

        // Keep last 20 entries
        if breadcrumbs.count > 20 {
            breadcrumbs = Array(breadcrumbs.suffix(20))
        }

        UserDefaults.standard.set(breadcrumbs, forKey: breadcrumbsKey)
    }

    /// Read and clear breadcrumbs (called from Flutter via MethodChannel drain).
    static func drainBreadcrumbs() -> [String] {
        let breadcrumbs =
            UserDefaults.standard.stringArray(forKey: breadcrumbsKey) ?? []
        UserDefaults.standard.set([String](), forKey: breadcrumbsKey)
        return breadcrumbs
    }
}

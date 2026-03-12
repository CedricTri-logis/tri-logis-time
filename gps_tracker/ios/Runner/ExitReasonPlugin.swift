import Flutter
import UIKit
import MetricKit

public class ExitReasonPlugin: NSObject, FlutterPlugin, MXMetricManagerSubscriber {

    private var channel: FlutterMethodChannel?
    private var pendingCrashes: [[String: Any]] = []
    private var pendingExitMetrics: [[String: Any]] = []

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = ExitReasonPlugin()
        let channel = FlutterMethodChannel(
            name: "gps_tracker/exit_reason",
            binaryMessenger: registrar.messenger()
        )
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)

        // Subscribe to MetricKit (replaces subscription in DiagnosticNativePlugin)
        if #available(iOS 13, *) {
            MXMetricManager.shared.add(instance)
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getExitMetrics":
            result(getExitMetrics())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Exit Metrics Collection

    private func getExitMetrics() -> [String: Any] {
        var response: [String: Any] = [
            "foreground": [:] as [String: Any],
            "background": [:] as [String: Any],
            "crashes": [] as [[String: Any]]
        ]

        // Return any pending crashes collected by MetricKit callbacks
        if !pendingCrashes.isEmpty {
            response["crashes"] = pendingCrashes
            pendingCrashes.removeAll()
        }

        // Read exit metrics from pastPayloads (iOS 14+)
        if #available(iOS 14, *) {
            let payloads = MXMetricManager.shared.pastPayloads
            let exitMetrics = extractExitMetrics(from: payloads)
            response["foreground"] = exitMetrics["foreground"] ?? [:]
            response["background"] = exitMetrics["background"] ?? [:]
            if let periodStart = exitMetrics["period_start"] {
                response["period_start"] = periodStart
            }
            if let periodEnd = exitMetrics["period_end"] {
                response["period_end"] = periodEnd
            }
        }

        return response
    }

    @available(iOS 14, *)
    private func extractExitMetrics(from payloads: [MXMetricPayload]) -> [String: Any] {
        let defaults = UserDefaults.standard
        let prefix = "exit_reason_last_"

        // Aggregate across all payloads
        var foreground: [String: Int] = [:]
        var background: [String: Int] = [:]
        var periodStart: String?
        var periodEnd: String?

        let formatter = ISO8601DateFormatter()

        for payload in payloads {
            let s = formatter.string(from: payload.timeStampBegin)
            if periodStart == nil || s < periodStart! { periodStart = s }

            let e = formatter.string(from: payload.timeStampEnd)
            if periodEnd == nil || e > periodEnd! { periodEnd = e }

            if #available(iOS 15, *) {
                if let exitMetric = payload.applicationExitMetrics {
                    // Foreground exits
                    let fg = exitMetric.foregroundExitData
                    foreground["normal"] = (foreground["normal"] ?? 0) + fg.cumulativeNormalAppExitCount
                    foreground["abnormal"] = (foreground["abnormal"] ?? 0) + fg.cumulativeAbnormalExitCount
                    foreground["memory_limit"] = (foreground["memory_limit"] ?? 0) + fg.cumulativeMemoryResourceLimitExitCount
                    foreground["memory_pressure"] = (foreground["memory_pressure"] ?? 0) + fg.cumulativeMemoryPressureExitCount
                    foreground["watchdog"] = (foreground["watchdog"] ?? 0) + fg.cumulativeAppWatchdogExitCount
                    foreground["cpu_limit"] = (foreground["cpu_limit"] ?? 0) + fg.cumulativeCPUResourceLimitExitCount
                    foreground["bad_access"] = (foreground["bad_access"] ?? 0) + fg.cumulativeBadAccessExitCount
                    foreground["illegal_instruction"] = (foreground["illegal_instruction"] ?? 0) + fg.cumulativeIllegalInstructionExitCount
                    foreground["suspended_locked_file"] = (foreground["suspended_locked_file"] ?? 0) + fg.cumulativeSuspendedWithLockedFileExitCount

                    // Background exits
                    let bg = exitMetric.backgroundExitData
                    background["normal"] = (background["normal"] ?? 0) + bg.cumulativeNormalAppExitCount
                    background["abnormal"] = (background["abnormal"] ?? 0) + bg.cumulativeAbnormalExitCount
                    background["memory_limit"] = (background["memory_limit"] ?? 0) + bg.cumulativeMemoryResourceLimitExitCount
                    background["memory_pressure"] = (background["memory_pressure"] ?? 0) + bg.cumulativeMemoryPressureExitCount
                    background["watchdog"] = (background["watchdog"] ?? 0) + bg.cumulativeAppWatchdogExitCount
                    background["cpu_limit"] = (background["cpu_limit"] ?? 0) + bg.cumulativeCPUResourceLimitExitCount
                    background["bad_access"] = (background["bad_access"] ?? 0) + bg.cumulativeBadAccessExitCount
                    background["illegal_instruction"] = (background["illegal_instruction"] ?? 0) + bg.cumulativeIllegalInstructionExitCount
                    background["suspended_locked_file"] = (background["suspended_locked_file"] ?? 0) + bg.cumulativeSuspendedWithLockedFileExitCount
                    background["background_task_timeout"] = (background["background_task_timeout"] ?? 0) + bg.cumulativeBackgroundTaskAssertionTimeoutExitCount
                }
            }
        }

        // Compute deltas against last-saved counters
        var fgDeltas: [String: Int] = [:]
        for (key, total) in foreground {
            let lastKey = "\(prefix)fg_\(key)"
            let lastValue = defaults.integer(forKey: lastKey)
            let delta = max(0, total - lastValue)
            if delta > 0 { fgDeltas[key] = delta }
            defaults.set(total, forKey: lastKey)
        }

        var bgDeltas: [String: Int] = [:]
        for (key, total) in background {
            let lastKey = "\(prefix)bg_\(key)"
            let lastValue = defaults.integer(forKey: lastKey)
            let delta = max(0, total - lastValue)
            if delta > 0 { bgDeltas[key] = delta }
            defaults.set(total, forKey: lastKey)
        }

        var result: [String: Any] = [
            "foreground": fgDeltas,
            "background": bgDeltas
        ]
        if let ps = periodStart { result["period_start"] = ps }
        if let pe = periodEnd { result["period_end"] = pe }

        return result
    }

    // MARK: - MXMetricManagerSubscriber

    @available(iOS 14, *)
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        // Buffer crash diagnostics for next getExitMetrics() call
        for payload in payloads {
            do {
                let json = payload.jsonRepresentation()
                if let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    if let crashes = dict["crashDiagnostics"] as? [[String: Any]] {
                        pendingCrashes.append(contentsOf: crashes)
                    }
                }
            } catch {
                // Silently ignore
            }
        }
    }

    @available(iOS 13, *)
    public func didReceive(_ payloads: [MXMetricPayload]) {
        // Metric payloads are read on-demand via pastPayloads in getExitMetrics()
        // No buffering needed here — just log for debugging
    }
}

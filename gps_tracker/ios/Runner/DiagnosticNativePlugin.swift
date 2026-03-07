import Flutter
import UIKit
import CoreLocation
import MetricKit

public class DiagnosticNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
    CLLocationManagerDelegate, MXMetricManagerSubscriber {

    private var eventSink: FlutterEventSink?
    private var memorySource: DispatchSourceMemoryPressure?
    private var locationManager: CLLocationManager?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = DiagnosticNativePlugin()
        let channel = FlutterEventChannel(
            name: "gps_tracker/diagnostic_native",
            binaryMessenger: registrar.messenger()
        )
        channel.setStreamHandler(instance)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.eventSink = events
        startMetricKit()
        startLocationMonitoring()
        startMemoryPressureMonitoring()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopAll()
        self.eventSink = nil
        return nil
    }

    // MARK: - MetricKit

    private func startMetricKit() {
        if #available(iOS 13, *) {
            MXMetricManager.shared.add(self)
        }
    }

    @available(iOS 14, *)
    public func didReceive(_ payloads: [MXDiagnosticPayload]) {
        do {
            for payload in payloads {
                let json = payload.jsonRepresentation()
                if let dict = try JSONSerialization.jsonObject(with: json) as? [String: Any] {
                    if let crashes = dict["crashDiagnostics"] as? [[String: Any]] {
                        for crash in crashes {
                            sendEvent(["type": "metrickit_crash", "data": crash])
                        }
                    }
                    let exitData: [String: Any] = [
                        "cumulativeForegroundExitCount":
                            dict["cumulativeForegroundExitCount"] ?? [:],
                        "cumulativeBackgroundExitCount":
                            dict["cumulativeBackgroundExitCount"] ?? [:]
                    ]
                    sendEvent(["type": "metrickit_exit", "data": exitData])
                }
            }
        } catch {
            // Silently ignore serialization failures
        }
    }

    // MARK: - Location Pause/Resume

    private func startLocationMonitoring() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.pausesLocationAutomatically = true
    }

    public func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        sendEvent(["type": "location_paused"])
    }

    public func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        sendEvent(["type": "location_resumed"])
    }

    // MARK: - Memory Pressure

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let event = source.data
            let level: String
            if event.contains(.critical) {
                level = "critical"
            } else {
                level = "warning"
            }
            self?.sendEvent(["type": "memory_pressure", "level": level])
        }
        source.resume()
        self.memorySource = source
    }

    // MARK: - Helpers

    private func sendEvent(_ dict: [String: Any]) {
        do {
            let data = try JSONSerialization.data(withJSONObject: dict)
            if let jsonString = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async {
                    self.eventSink?(jsonString)
                }
            }
        } catch {
            // Silently ignore serialization failures
        }
    }

    private func stopAll() {
        if #available(iOS 13, *) {
            MXMetricManager.shared.remove(self)
        }
        memorySource?.cancel()
        memorySource = nil
        locationManager?.delegate = nil
        locationManager = nil
    }
}

import Flutter
import UIKit
import CoreLocation

public class DiagnosticNativePlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
    CLLocationManagerDelegate {

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
        startLocationMonitoring()
        startMemoryPressureMonitoring()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        stopAll()
        self.eventSink = nil
        return nil
    }

    // MARK: - Location Pause/Resume

    private func startLocationMonitoring() {
        locationManager = CLLocationManager()
        locationManager?.delegate = self
        locationManager?.pausesLocationUpdatesAutomatically = true
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
        memorySource?.cancel()
        memorySource = nil
        locationManager?.delegate = nil
        locationManager = nil
    }
}

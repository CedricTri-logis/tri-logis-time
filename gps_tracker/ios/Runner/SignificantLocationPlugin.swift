import Flutter
import CoreLocation

/// Native iOS plugin for Significant Location Change monitoring.
///
/// This service uses cell tower triangulation (not GPS) to detect when the
/// device moves ~500m+. Its critical feature: iOS relaunches the app even
/// after termination when a significant location change is detected.
/// This acts as a safety net to restart GPS tracking if iOS kills the app.
class SignificantLocationPlugin: NSObject, FlutterPlugin, CLLocationManagerDelegate {
    private var locationManager: CLLocationManager?
    private var channel: FlutterMethodChannel?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "gps_tracker/significant_location",
            binaryMessenger: registrar.messenger()
        )
        let instance = SignificantLocationPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startMonitoring":
            startMonitoring()
            result(true)
        case "stopMonitoring":
            stopMonitoring()
            result(true)
        case "isMonitoring":
            result(locationManager != nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func startMonitoring() {
        guard CLLocationManager.significantLocationChangeMonitoringAvailable() else {
            channel?.invokeMethod("onSignificantLocationMonitoringError", arguments: [
                "error_code": "not_available",
                "message": "Significant location change monitoring is not available on this device"
            ])
            return
        }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.allowsBackgroundLocationUpdates = true
        manager.startMonitoringSignificantLocationChanges()
        locationManager = manager
        channel?.invokeMethod("onSignificantLocationMonitoringStarted", arguments: nil)
    }

    private func stopMonitoring() {
        locationManager?.stopMonitoringSignificantLocationChanges()
        locationManager = nil
        channel?.invokeMethod("onSignificantLocationMonitoringStopped", arguments: nil)
    }

    // Called when iOS detects a significant location change.
    // This fires even if the app was terminated — iOS relaunches it.
    func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        // Notify Flutter that the app was woken by a significant location change
        channel?.invokeMethod("onSignificantLocationChange", arguments: [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "timestamp": location.timestamp.timeIntervalSince1970,
        ])
    }

    func locationManager(
        _ manager: CLLocationManager,
        didFailWithError error: Error
    ) {
        let nsError = error as NSError
        channel?.invokeMethod("onSignificantLocationMonitoringError", arguments: [
            "error_code": "\(nsError.code)",
            "error_domain": nsError.domain,
            "message": nsError.localizedDescription
        ])
    }
}

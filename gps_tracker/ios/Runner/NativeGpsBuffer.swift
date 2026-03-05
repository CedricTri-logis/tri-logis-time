import Foundation
import CoreLocation

class NativeGpsBuffer {
    static let shared = NativeGpsBuffer()
    private let key = "native_gps_buffer_points"
    private let maxPoints = 500

    func save(location: CLLocation, shiftId: String) {
        var points = load()

        let point: [String: Any] = [
            "shift_id": shiftId,
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "altitude": location.altitude,
            "speed": max(0, location.speed),
            "heading": max(0, location.course),
            "captured_at": Int(location.timestamp.timeIntervalSince1970 * 1000),
            "source": "native_slc"
        ]

        points.append(point)

        // Trim to max size
        if points.count > maxPoints {
            points = Array(points.suffix(maxPoints))
        }

        if let data = try? JSONSerialization.data(withJSONObject: points),
           let json = String(data: data, encoding: .utf8) {
            UserDefaults.standard.set(json, forKey: key)
        }
    }

    func drain() -> String {
        let points = load()
        UserDefaults.standard.set("[]", forKey: key)
        if let data = try? JSONSerialization.data(withJSONObject: points),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return "[]"
    }

    func count() -> Int {
        return load().count
    }

    private func load() -> [[String: Any]] {
        guard let json = UserDefaults.standard.string(forKey: key),
              let data = json.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return array
    }
}

import Foundation
import CoreLocation

/// Stores GPS points captured natively (outside Flutter) as JSONL (one JSON object per line).
/// Flutter reads and drains this buffer on resume via MethodChannel.
///
/// Thread safety: all operations are serialized on a private DispatchQueue.
/// Migration: on first drain(), any leftover data in the old UserDefaults key is merged.
class NativeGpsBuffer {
    static let shared = NativeGpsBuffer()

    private let fileName = "native_gps_buffer.jsonl"
    private let queue = DispatchQueue(label: "ca.trilogis.gpstracker.native-gps-buffer")

    // Old UserDefaults key (for one-time migration)
    private let oldKey = "native_gps_buffer_points"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return dir.appendingPathComponent(fileName)
    }

    private func ensureDirectory() {
        let dir = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    func save(location: CLLocation, shiftId: String) {
        queue.sync {
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

            guard let data = try? JSONSerialization.data(withJSONObject: point),
                  var line = String(data: data, encoding: .utf8) else { return }

            line += "\n"

            ensureDirectory()

            let path = fileURL.path
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil)
            }

            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { handle.closeFile() }
            handle.seekToEndOfFile()
            if let lineData = line.data(using: .utf8) {
                handle.write(lineData)
            }
        }
    }

    func drain() -> String {
        return queue.sync {
            var points: [[String: Any]] = []

            // --- One-time migration from old UserDefaults ---
            let oldJson = UserDefaults.standard.string(forKey: oldKey) ?? "[]"
            if oldJson != "[]",
               let oldData = oldJson.data(using: .utf8),
               let oldArray = try? JSONSerialization.jsonObject(with: oldData) as? [[String: Any]] {
                points.append(contentsOf: oldArray)
                UserDefaults.standard.set("[]", forKey: oldKey)
            }

            // --- Read JSONL file ---
            let path = fileURL.path
            if FileManager.default.fileExists(atPath: path) {
                if let content = try? String(contentsOfFile: path, encoding: .utf8) {
                    let lines = content.components(separatedBy: "\n")
                    for line in lines {
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { continue }
                        if let data = trimmed.data(using: .utf8),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            points.append(obj)
                        }
                        // else: corrupted/truncated line — skip
                    }
                }
                try? FileManager.default.removeItem(atPath: path)
            }

            // Return JSON array string (same format as before)
            if let data = try? JSONSerialization.data(withJSONObject: points),
               let json = String(data: data, encoding: .utf8) {
                return json
            }
            return "[]"
        }
    }

    func count() -> Int {
        return queue.sync {
            let path = fileURL.path
            guard FileManager.default.fileExists(atPath: path),
                  let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                return 0
            }
            return content.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .count
        }
    }
}

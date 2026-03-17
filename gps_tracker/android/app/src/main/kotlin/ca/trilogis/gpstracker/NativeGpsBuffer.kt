package ca.trilogis.gpstracker

import android.content.Context
import android.location.Location
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedWriter
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStreamWriter
import java.util.UUID

/**
 * Stores GPS points captured natively (outside Flutter) as JSONL (one JSON object per line).
 * Flutter reads and drains this buffer on resume via MethodChannel.
 *
 * Migration: On first drain() after app update, any leftover data in the old
 * SharedPreferences store is merged into the result and the old key is cleared.
 */
object NativeGpsBuffer {
    private const val FILE_NAME = "native_gps_buffer.jsonl"

    // Old SharedPreferences keys (for one-time migration)
    private const val OLD_PREFS_NAME = "native_gps_buffer"
    private const val OLD_KEY_POINTS = "points"

    fun save(context: Context, shiftId: String, location: Location) {
        val point = JSONObject().apply {
            put("shift_id", shiftId)
            put("latitude", location.latitude)
            put("longitude", location.longitude)
            put("accuracy", location.accuracy.toDouble())
            put("altitude", location.altitude)
            put("speed", location.speed.toDouble())
            put("heading", location.bearing.toDouble())
            put("captured_at", System.currentTimeMillis())
            put("source", "native_rescue")
            val clientId = UUID.nameUUIDFromBytes(
                "$shiftId:${location.time}".toByteArray()
            ).toString()
            put("client_id", clientId)
        }

        try {
            val file = File(context.filesDir, FILE_NAME)
            FileOutputStream(file, true).use { fos ->
                OutputStreamWriter(fos, Charsets.UTF_8).use { writer ->
                    BufferedWriter(writer).use { bw ->
                        bw.write(point.toString())
                        bw.newLine()
                        bw.flush()
                    }
                }
            }
        } catch (_: Exception) {
            // IOException / disk full — skip this point, next alarm will retry
        }
    }

    fun drain(context: Context): String {
        val result = JSONArray()

        // --- One-time migration from old SharedPreferences ---
        try {
            val prefs = context.getSharedPreferences(OLD_PREFS_NAME, Context.MODE_PRIVATE)
            val oldJson = prefs.getString(OLD_KEY_POINTS, "[]") ?: "[]"
            if (oldJson != "[]") {
                val oldArray = JSONArray(oldJson)
                for (i in 0 until oldArray.length()) {
                    result.put(oldArray.getJSONObject(i))
                }
                prefs.edit().putString(OLD_KEY_POINTS, "[]").apply()
            }
        } catch (_: Exception) {
            // Migration failed — old data may be lost, but don't crash
        }

        // --- Read JSONL file ---
        val file = File(context.filesDir, FILE_NAME)
        if (file.exists()) {
            try {
                file.bufferedReader(Charsets.UTF_8).useLines { lines ->
                    for (line in lines) {
                        val trimmed = line.trim()
                        if (trimmed.isEmpty()) continue
                        try {
                            result.put(JSONObject(trimmed))
                        } catch (_: Exception) {
                            // Corrupted/truncated line (e.g. SIGKILL mid-write) — skip
                        }
                    }
                }
            } catch (_: Exception) {
                // File read error — return whatever we have from migration
            }
            file.delete()
        }

        return result.toString()
    }

    fun count(context: Context): Int {
        val file = File(context.filesDir, FILE_NAME)
        if (!file.exists()) return 0
        return try {
            file.bufferedReader(Charsets.UTF_8).useLines { lines ->
                lines.count { it.trim().isNotEmpty() }
            }
        } catch (_: Exception) {
            0
        }
    }
}

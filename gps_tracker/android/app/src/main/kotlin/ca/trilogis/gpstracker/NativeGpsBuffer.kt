package ca.trilogis.gpstracker

import android.content.Context
import android.location.Location
import org.json.JSONArray
import org.json.JSONObject

/**
 * Stores GPS points captured natively (outside Flutter) in SharedPreferences.
 * Flutter reads and drains this buffer on resume via MethodChannel.
 */
object NativeGpsBuffer {
    private const val PREFS_NAME = "native_gps_buffer"
    private const val KEY_POINTS = "points"
    private const val MAX_POINTS = 500

    fun save(context: Context, shiftId: String, location: Location) {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val points = getPointsArray(prefs.getString(KEY_POINTS, "[]")!!)

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
        }

        points.put(point)

        // Trim to max size (remove oldest first)
        while (points.length() > MAX_POINTS) {
            points.remove(0)
        }

        prefs.edit().putString(KEY_POINTS, points.toString()).apply()
    }

    fun drain(context: Context): String {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val json = prefs.getString(KEY_POINTS, "[]")!!
        prefs.edit().putString(KEY_POINTS, "[]").apply()
        return json
    }

    fun count(context: Context): Int {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        return getPointsArray(prefs.getString(KEY_POINTS, "[]")!!).length()
    }

    private fun getPointsArray(json: String): JSONArray {
        return try { JSONArray(json) } catch (_: Exception) { JSONArray() }
    }
}

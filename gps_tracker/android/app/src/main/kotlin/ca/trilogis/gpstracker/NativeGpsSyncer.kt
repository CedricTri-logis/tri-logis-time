package ca.trilogis.gpstracker

import android.content.Context
import android.util.Log
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * Syncs native GPS buffer directly to Supabase via HTTP POST.
 * Used by TrackingRescueReceiver when the Dart engine is dead.
 *
 * Reads Supabase credentials from FlutterForegroundTask SharedPreferences
 * (saved by BackgroundTrackingService.startTracking() on the Dart side).
 */
object NativeGpsSyncer {
    private const val TAG = "NativeGpsSyncer"
    private const val FGT_PREFS = "FlutterSharedPreferences"
    private const val KEY_PREFIX = "flutter.com.pravera.flutter_foreground_task.prefs."

    private val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .writeTimeout(10, TimeUnit.SECONDS)
        .readTimeout(10, TimeUnit.SECONDS)
        .build()

    /**
     * Attempt to sync all buffered native GPS points to Supabase.
     * Returns the number of points successfully synced (and removed from buffer).
     * Returns 0 on any failure — points remain in buffer for later drain by Dart.
     *
     * MUST be called from a background thread (performs network I/O).
     */
    fun syncBufferedPoints(context: Context): Int {
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)

        val supabaseUrl = prefs.getString("${KEY_PREFIX}supabase_url", null)
        val supabaseKey = prefs.getString("${KEY_PREFIX}supabase_anon_key", null)
        val employeeId = prefs.getString("${KEY_PREFIX}employee_id", null)

        if (supabaseUrl == null || supabaseKey == null || employeeId == null) {
            Log.d(TAG, "Missing Supabase credentials or employee_id — skipping native sync")
            return 0
        }

        val bufferPrefs = context.getSharedPreferences("native_gps_buffer", Context.MODE_PRIVATE)
        val json = bufferPrefs.getString("points", null)
        if (json.isNullOrEmpty() || json == "[]") return 0

        return try {
            val points = JSONArray(json)
            if (points.length() == 0) return 0

            val payload = JSONArray()
            for (i in 0 until points.length()) {
                val p = points.getJSONObject(i)
                val row = JSONObject().apply {
                    put("client_id", p.optString("client_id", java.util.UUID.randomUUID().toString()))
                    put("shift_id", p.getString("shift_id"))
                    put("employee_id", employeeId)
                    put("latitude", p.getDouble("latitude"))
                    put("longitude", p.getDouble("longitude"))
                    put("accuracy", p.getDouble("accuracy"))
                    put("speed", p.optDouble("speed", 0.0))
                    put("altitude", p.optDouble("altitude", 0.0))
                    put("heading", p.optDouble("heading", 0.0))
                    val capturedMs = p.getLong("captured_at")
                    val iso = java.text.SimpleDateFormat(
                        "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'",
                        java.util.Locale.US
                    ).apply {
                        timeZone = java.util.TimeZone.getTimeZone("UTC")
                    }.format(java.util.Date(capturedMs))
                    put("captured_at", iso)
                }
                payload.put(row)
            }

            val url = "$supabaseUrl/rest/v1/gps_points"
            val body = payload.toString()
                .toRequestBody("application/json".toMediaType())

            val request = Request.Builder()
                .url(url)
                .post(body)
                .addHeader("apikey", supabaseKey)
                .addHeader("Authorization", "Bearer $supabaseKey")
                .addHeader("Content-Type", "application/json")
                .addHeader("Prefer", "resolution=ignore-duplicates")
                .build()

            val response = client.newCall(request).execute()
            response.use {
                if (it.isSuccessful) {
                    val count = points.length()
                    bufferPrefs.edit().putString("points", "[]").apply()
                    Log.i(TAG, "Synced $count native GPS points to Supabase")
                    count
                } else {
                    Log.w(TAG, "Supabase POST failed: ${it.code} ${it.body?.string()?.take(200)}")
                    0
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Native sync failed: ${e.message}")
            0
        }
    }
}

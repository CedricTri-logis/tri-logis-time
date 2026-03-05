package ca.trilogis.gpstracker

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * BroadcastReceiver that forms a 45-second AlarmManager chain to rescue
 * the flutter_foreground_task (FFT) GPS tracking service if Android kills it.
 *
 * Chain logic:
 *   startAlarmChain() → alarm fires → onReceive() → restart FFT service
 *                                                  → startAlarmChain() (next alarm)
 *
 * The chain stops naturally when shift_id is cleared (clock-out), or explicitly
 * via stopAlarmChain() called from Flutter.
 *
 * Android 16 (SDK 36) fix: uses setAlarmClock() as primary alarm mechanism.
 * setAlarmClock() is never throttled by doze mode or battery optimization,
 * and its callback is allowed to start foreground services from background.
 */
class TrackingRescueReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingRescueReceiver"
        const val ACTION_RESCUE_ALARM = "ca.trilogis.gpstracker.ACTION_RESCUE_ALARM"

        // SharedPreferences keys (same format as FlutterForegroundTask)
        private const val FGT_PREFS = "FlutterSharedPreferences"
        private const val KEY_SHIFT_ID =
            "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"
        private const val KEY_WATCHDOG_LOG =
            "flutter.com.pravera.flutter_foreground_task.prefs.watchdog_log"

        private const val RESCUE_INTERVAL_MS = 45_000L // 45s (was 60s)
        private const val REQUEST_CODE = 9877

        /**
         * Start the 45-second rescue alarm chain. Safe to call multiple times.
         *
         * Uses setAlarmClock() as primary — the most reliable alarm on Android:
         * - Fires even in doze mode
         * - Never throttled by battery optimization or Android 16 alarm restrictions
         * - Callback is allowed to start foreground services from background (API 34+)
         * - Shows alarm icon in status bar (acceptable for GPS tracking app)
         */
        fun startAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return

            // Primary: setAlarmClock() — most reliable, no permission needed
            if (trySetAlarmClock(context, alarmManager, pendingIntent)) return

            // Fallback: exact alarm (needs SCHEDULE_EXACT_ALARM on API 31+)
            if (trySetExactAlarm(alarmManager, pendingIntent)) return

            // Last resort: inexact alarm (may be delayed on Android 16)
            val triggerTime = SystemClock.elapsedRealtime() + RESCUE_INTERVAL_MS
            alarmManager.setAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerTime,
                pendingIntent
            )
            Log.d(TAG, "Inexact rescue alarm scheduled (last resort)")
        }

        private fun trySetAlarmClock(
            context: Context,
            alarmManager: AlarmManager,
            operationIntent: PendingIntent
        ): Boolean {
            return try {
                val triggerTime = System.currentTimeMillis() + RESCUE_INTERVAL_MS
                val showIntent = PendingIntent.getActivity(
                    context,
                    0,
                    context.packageManager.getLaunchIntentForPackage(context.packageName)
                        ?: Intent(),
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val alarmClockInfo = AlarmManager.AlarmClockInfo(triggerTime, showIntent)
                alarmManager.setAlarmClock(alarmClockInfo, operationIntent)
                Log.d(TAG, "AlarmClock rescue scheduled in ${RESCUE_INTERVAL_MS / 1000}s")
                true
            } catch (e: Exception) {
                Log.w(TAG, "setAlarmClock failed: ${e.message}")
                false
            }
        }

        private fun trySetExactAlarm(
            alarmManager: AlarmManager,
            pendingIntent: PendingIntent
        ): Boolean {
            val triggerTime = SystemClock.elapsedRealtime() + RESCUE_INTERVAL_MS

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!alarmManager.canScheduleExactAlarms()) {
                    return false
                }
            }

            return try {
                alarmManager.setExactAndAllowWhileIdle(
                    AlarmManager.ELAPSED_REALTIME_WAKEUP,
                    triggerTime,
                    pendingIntent
                )
                Log.d(TAG, "Exact rescue alarm scheduled in ${RESCUE_INTERVAL_MS / 1000}s")
                true
            } catch (e: Exception) {
                Log.w(TAG, "setExactAndAllowWhileIdle failed: ${e.message}")
                false
            }
        }

        /**
         * Cancel the rescue alarm chain. Call when tracking ends.
         */
        fun stopAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return
            alarmManager.cancel(pendingIntent)
            pendingIntent.cancel()
            GeofenceWakeReceiver.remove(context)
            Log.d(TAG, "Rescue alarm chain stopped")
        }

        private fun buildPendingIntent(context: Context): PendingIntent? {
            val intent = Intent(context, TrackingRescueReceiver::class.java).apply {
                action = ACTION_RESCUE_ALARM
            }
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        /**
         * Write a breadcrumb log entry to SharedPreferences (same key as WorkManager watchdog).
         * Format: "timestamp|rescue|outcome|shiftId"
         * Read and cleared by the main app on resume via TrackingWatchdogService.consumeLog().
         */
        private fun writeLog(context: Context, outcome: String, shiftId: String?) {
            try {
                val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
                val existing = prefs.getString(KEY_WATCHDOG_LOG, "") ?: ""
                val now = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US)
                    .apply { timeZone = TimeZone.getTimeZone("UTC") }
                    .format(Date())
                val entry = "$now|rescue|$outcome|${shiftId ?: ""}"

                val lines = if (existing.isEmpty()) mutableListOf()
                else existing.split("\n").toMutableList()
                lines.add(entry)
                while (lines.size > 20) lines.removeAt(0)

                prefs.edit()
                    .putString(KEY_WATCHDOG_LOG, lines.joinToString("\n"))
                    .apply()
            } catch (_: Exception) {
                // Best-effort — never crash for logging
            }
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent?.action != ACTION_RESCUE_ALARM) return

        // Read shift_id from FFT SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            // No active shift — stop the chain naturally (don't reschedule)
            Log.d(TAG, "Rescue alarm fired but no active shift — chain stopped")
            writeLog(context, "no_shift", null)
            return
        }

        Log.d(TAG, "Rescue alarm fired, shift $shiftId active — restarting FFT service")

        // Unconditionally start the FFT foreground service.
        // If already running, this is harmless (just calls onStartCommand() again).
        try {
            val serviceIntent = Intent().apply {
                setClassName(
                    context.packageName,
                    "com.pravera.flutter_foreground_task.service.ForegroundService"
                )
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.i(TAG, "FFT service restart attempted for shift $shiftId")
            writeLog(context, "restart_attempted", shiftId)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart FFT service: ${e.message}")
            writeLog(context, "restart_failed:${e.javaClass.simpleName}", shiftId)
        }

        // Capture GPS point natively as backup
        try {
            val fusedClient = com.google.android.gms.location.LocationServices
                .getFusedLocationProviderClient(context)
            val cancellationSource = com.google.android.gms.tasks.CancellationTokenSource()

            fusedClient.getCurrentLocation(
                com.google.android.gms.location.Priority.PRIORITY_HIGH_ACCURACY,
                cancellationSource.token
            ).addOnSuccessListener { location ->
                if (location != null && shiftId != null) {
                    NativeGpsBuffer.save(context, shiftId, location)
                    // Register wake geofence around current position
                    // If employee moves 200m, GeofenceWakeReceiver restarts tracking
                    GeofenceWakeReceiver.register(context, location.latitude, location.longitude)
                    writeLog(context, "native_gps_captured", shiftId)
                }
            }.addOnFailureListener {
                // Fail silently — rescue alarm continues regardless
            }

            // Cancel after 10 seconds to avoid hanging
            android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                cancellationSource.cancel()
            }, 10_000)
        } catch (_: SecurityException) {
            // Location permission not granted — skip native capture
        } catch (_: Exception) {
            // Any other error — skip native capture
        }

        // Schedule the next alarm — continue the chain
        startAlarmChain(context)
    }
}

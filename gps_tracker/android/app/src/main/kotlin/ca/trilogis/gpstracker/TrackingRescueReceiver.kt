package ca.trilogis.gpstracker

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.SystemClock
import android.util.Log

/**
 * BroadcastReceiver that forms a 60-second AlarmManager chain to rescue
 * the flutter_foreground_task (FFT) GPS tracking service if Android kills it.
 *
 * Chain logic:
 *   startAlarmChain() → alarm fires → onReceive() → restart FFT service
 *                                                 → startAlarmChain() (next alarm)
 *
 * The chain stops naturally when shift_id is cleared (clock-out), or explicitly
 * via stopAlarmChain() called from Flutter.
 */
class TrackingRescueReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingRescueReceiver"
        const val ACTION_RESCUE_ALARM = "ca.trilogis.gpstracker.ACTION_RESCUE_ALARM"

        // SharedPreferences keys (same format as FlutterForegroundTask)
        private const val FGT_PREFS = "FlutterSharedPreferences"
        private const val KEY_SHIFT_ID =
            "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"

        private const val RESCUE_INTERVAL_MS = 60_000L
        private const val REQUEST_CODE = 9877 // Must not conflict with other PendingIntents

        /**
         * Start the 60-second rescue alarm chain. Safe to call multiple times.
         */
        fun startAlarmChain(context: Context) {
            val alarmManager =
                context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            val pendingIntent = buildPendingIntent(context) ?: return
            val triggerTime = SystemClock.elapsedRealtime() + RESCUE_INTERVAL_MS

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!alarmManager.canScheduleExactAlarms()) {
                    // Android 12+ without SCHEDULE_EXACT_ALARM: use inexact alarm.
                    // WorkManager 5-min watchdog covers the gap.
                    alarmManager.setAndAllowWhileIdle(
                        AlarmManager.ELAPSED_REALTIME_WAKEUP,
                        triggerTime,
                        pendingIntent
                    )
                    Log.d(TAG, "Inexact rescue alarm scheduled (no exact alarm permission)")
                    return
                }
            }

            alarmManager.setExactAndAllowWhileIdle(
                AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerTime,
                pendingIntent
            )
            Log.d(TAG, "Exact rescue alarm scheduled in ${RESCUE_INTERVAL_MS / 1000}s")
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
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent?.action != ACTION_RESCUE_ALARM) return

        // Read shift_id from FFT SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            // No active shift — stop the chain naturally (don't reschedule)
            Log.d(TAG, "Rescue alarm fired but no active shift — chain stopped")
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
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart FFT service: ${e.message}")
        }

        // Schedule the next alarm — continue the chain
        startAlarmChain(context)
    }
}

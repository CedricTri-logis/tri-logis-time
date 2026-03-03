package ca.trilogis.gpstracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * BroadcastReceiver that restarts the GPS tracking foreground service
 * after device boot or app update if there was an active shift.
 *
 * This receiver actively restarts the service (not just logging),
 * and starts the rescue alarm chain for ongoing protection.
 */
class TrackingBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingBootReceiver"
        private const val FGT_PREFS = "FlutterSharedPreferences"
        private const val KEY_SHIFT_ID = "flutter.com.pravera.flutter_foreground_task.prefs.shift_id"
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        val action = intent.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED) {
            return
        }

        Log.d(TAG, "Received $action — checking for active shift")

        // Read shift_id from flutter_foreground_task's SharedPreferences
        val prefs = context.getSharedPreferences(FGT_PREFS, Context.MODE_PRIVATE)
        val shiftId = prefs.getString(KEY_SHIFT_ID, null)

        if (shiftId.isNullOrEmpty()) {
            Log.d(TAG, "No active shift — skipping service restart")
            return
        }

        Log.i(TAG, "Active shift found ($shiftId) — restarting service after $action")

        // Restart the foreground service
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
            Log.i(TAG, "FFT service restart attempted after $action for shift $shiftId")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart FFT service after $action: ${e.message}")
        }

        // Start the rescue alarm chain for ongoing protection
        TrackingRescueReceiver.startAlarmChain(context)
    }
}

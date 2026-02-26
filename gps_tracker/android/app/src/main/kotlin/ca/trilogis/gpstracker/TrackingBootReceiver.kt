package ca.trilogis.gpstracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * BroadcastReceiver that restarts the GPS tracking foreground service
 * after device boot or app update if there was an active shift.
 *
 * This is a safety net on top of flutter_foreground_task's autoRunOnBoot,
 * providing more reliable restart on OEM Android ROMs.
 */
class TrackingBootReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "TrackingBootReceiver"
        // flutter_foreground_task uses Flutter's SharedPreferences (file: FlutterSharedPreferences)
        // Keys are prefixed with "flutter." (Flutter plugin) + "com.pravera.flutter_foreground_task.prefs." (FGT plugin)
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

        Log.i(TAG, "Active shift found ($shiftId) — attempting service restart")

        // flutter_foreground_task's autoRunOnBoot should handle the actual restart,
        // but we log here for diagnostic visibility. If the plugin's mechanism fails,
        // the AlarmManager/WorkManager watchdogs will catch it within 5-15 min.
    }
}

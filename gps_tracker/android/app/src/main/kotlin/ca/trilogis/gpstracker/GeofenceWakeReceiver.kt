package ca.trilogis.gpstracker

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import com.google.android.gms.location.Geofence
import com.google.android.gms.location.GeofencingEvent
import com.google.android.gms.location.GeofencingRequest
import com.google.android.gms.location.LocationServices

/**
 * Receives geofence exit transitions and restarts GPS tracking.
 *
 * When TrackingRescueReceiver detects that the Flutter foreground service is dead,
 * it registers a 200m geofence around the employee's current position. When the
 * employee moves beyond 200m, this receiver fires and restarts tracking + alarm chain.
 *
 * This is a belt-and-suspenders mechanism that works offline (no FCM needed).
 */
class GeofenceWakeReceiver : BroadcastReceiver() {

    companion object {
        private const val TAG = "GeofenceWakeReceiver"
        private const val GEOFENCE_ID = "tracking_wake_geofence"
        private const val REQUEST_CODE = 9878
        private const val RADIUS_METERS = 200f
        private const val EXPIRATION_MS = 3_600_000L // 1 hour

        /**
         * Register a wake geofence around the given coordinates.
         * When the employee exits this 200m radius, [GeofenceWakeReceiver] fires.
         */
        fun register(context: Context, latitude: Double, longitude: Double) {
            try {
                val geofence = Geofence.Builder()
                    .setRequestId(GEOFENCE_ID)
                    .setCircularRegion(latitude, longitude, RADIUS_METERS)
                    .setExpirationDuration(EXPIRATION_MS)
                    .setTransitionTypes(Geofence.GEOFENCE_TRANSITION_EXIT)
                    .build()

                val request = GeofencingRequest.Builder()
                    .setInitialTrigger(0) // Don't trigger immediately
                    .addGeofence(geofence)
                    .build()

                val client = LocationServices.getGeofencingClient(context)
                client.addGeofences(request, buildPendingIntent(context))
                    .addOnSuccessListener {
                        Log.d(TAG, "Wake geofence registered at $latitude,$longitude (${RADIUS_METERS}m)")
                    }
                    .addOnFailureListener { e ->
                        Log.w(TAG, "Failed to register wake geofence: ${e.message}")
                    }
            } catch (e: SecurityException) {
                Log.w(TAG, "No background location permission for geofence")
            } catch (e: Exception) {
                Log.w(TAG, "Geofence registration error: ${e.message}")
            }
        }

        /**
         * Remove the wake geofence. Called when tracking resumes normally.
         */
        fun remove(context: Context) {
            try {
                val client = LocationServices.getGeofencingClient(context)
                client.removeGeofences(listOf(GEOFENCE_ID))
                Log.d(TAG, "Wake geofence removed")
            } catch (_: Exception) {
                // Best-effort
            }
        }

        private fun buildPendingIntent(context: Context): PendingIntent {
            val intent = Intent(context, GeofenceWakeReceiver::class.java)
            return PendingIntent.getBroadcast(
                context,
                REQUEST_CODE,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )
        }
    }

    override fun onReceive(context: Context?, intent: Intent?) {
        if (context == null || intent == null) return

        val event = GeofencingEvent.fromIntent(intent)
        if (event == null || event.hasError()) {
            Log.w(TAG, "Geofence event error: ${event?.errorCode}")
            return
        }

        Log.i(TAG, "Geofence exit detected — restarting tracking")

        // Restart FFT foreground service
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
            Log.i(TAG, "FFT service restart attempted from geofence wake")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart FFT from geofence: ${e.message}")
        }

        // Restart the rescue alarm chain
        TrackingRescueReceiver.startAlarmChain(context)

        // Remove the geofence (one-shot — will be re-registered by rescue alarm if needed)
        remove(context)
    }
}

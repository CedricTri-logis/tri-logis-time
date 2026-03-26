package ca.trilogis.gpstracker

import android.app.usage.UsageStatsManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.location.GnssStatus
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject

class DiagnosticNativePlugin(private val context: Context) {

    companion object {
        private const val EVENT_CHANNEL = "gps_tracker/diagnostic_native"
        private const val METHOD_CHANNEL = "gps_tracker/diagnostic_native/control"
        private const val GNSS_THROTTLE_MS = 60_000L
        private const val BUCKET_CHECK_INTERVAL_MS = 5 * 60_000L

        fun register(messenger: BinaryMessenger, context: Context) {
            val plugin = DiagnosticNativePlugin(context)
            plugin.setupChannels(messenger)
        }
    }

    private var eventSink: EventChannel.EventSink? = null
    private var isMonitoring = false
    private val handler = Handler(Looper.getMainLooper())

    // GNSS state
    private var gnssCallback: GnssStatus.Callback? = null
    private var lastGnssSendTime = 0L

    // Doze state
    private var dozeReceiver: BroadcastReceiver? = null

    // Standby bucket state
    private var lastBucket = -1
    private var bucketRunnable: Runnable? = null

    private fun setupChannels(messenger: BinaryMessenger) {
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startMonitoring" -> {
                    startMonitoring()
                    result.success(true)
                }
                "stopMonitoring" -> {
                    stopMonitoring()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun startMonitoring() {
        if (isMonitoring) return
        isMonitoring = true
        startGnssMonitoring()
        startDozeMonitoring()
        startBucketMonitoring()
    }

    private fun stopMonitoring() {
        if (!isMonitoring) return
        isMonitoring = false
        stopGnssMonitoring()
        stopDozeMonitoring()
        stopBucketMonitoring()
    }

    // --- GNSS Satellite Status (API 24+) ---

    private fun startGnssMonitoring() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        try {
            val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager ?: return
            gnssCallback = object : GnssStatus.Callback() {
                override fun onSatelliteStatusChanged(status: GnssStatus) {
                    try {
                        val now = System.currentTimeMillis()
                        val count = status.satelliteCount
                        var cn0Sum = 0f
                        var usedCount = 0
                        for (i in 0 until count) {
                            cn0Sum += status.getCn0DbHz(i)
                            if (status.usedInFix(i)) usedCount++
                        }
                        val avgCn0 = if (count > 0) cn0Sum / count else 0f
                        val shouldSend = (now - lastGnssSendTime >= GNSS_THROTTLE_MS) || usedCount < 4
                        if (shouldSend) {
                            lastGnssSendTime = now
                            sendEvent(JSONObject().apply {
                                put("type", "gnss_status")
                                put("satellite_count", usedCount)
                                put("avg_cn0", "%.1f".format(avgCn0).toDouble())
                                put("ttff_ms", 0)
                            })
                        }
                    } catch (_: Exception) {}
                }

                override fun onFirstFix(ttffMillis: Int) {
                    try {
                        sendEvent(JSONObject().apply {
                            put("type", "gnss_first_fix")
                            put("ttff_ms", ttffMillis)
                        })
                    } catch (_: Exception) {}
                }
            }
            locationManager.registerGnssStatusCallback(gnssCallback!!, handler)
        } catch (_: SecurityException) {
        } catch (_: Exception) {}
    }

    private fun stopGnssMonitoring() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return
        try {
            gnssCallback?.let {
                val locationManager = context.getSystemService(Context.LOCATION_SERVICE) as? LocationManager
                locationManager?.unregisterGnssStatusCallback(it)
            }
            gnssCallback = null
        } catch (_: Exception) {}
    }

    // --- Doze Mode Detection ---

    private fun startDozeMonitoring() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
        try {
            dozeReceiver = object : BroadcastReceiver() {
                override fun onReceive(ctx: Context?, intent: Intent?) {
                    try {
                        val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
                        sendEvent(JSONObject().apply {
                            put("type", "doze_changed")
                            put("is_idle", pm.isDeviceIdleMode)
                        })
                    } catch (_: Exception) {}
                }
            }
            val filter = IntentFilter(PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                context.registerReceiver(dozeReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                context.registerReceiver(dozeReceiver, filter)
            }
        } catch (_: Exception) {}
    }

    private fun stopDozeMonitoring() {
        try {
            dozeReceiver?.let { context.unregisterReceiver(it) }
            dozeReceiver = null
        } catch (_: Exception) {}
    }

    // --- Standby Bucket Monitoring ---

    private fun startBucketMonitoring() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) return
        lastBucket = -1
        bucketRunnable = object : Runnable {
            override fun run() {
                if (!isMonitoring) return
                try {
                    val usm = context.getSystemService(Context.USAGE_STATS_SERVICE) as? UsageStatsManager
                    val bucket = usm?.appStandbyBucket ?: -1
                    if (bucket != lastBucket) {
                        lastBucket = bucket
                        sendEvent(JSONObject().apply {
                            put("type", "standby_bucket_changed")
                            put("bucket", bucket)
                            put("bucket_name", bucketName(bucket))
                        })
                    }
                } catch (_: Exception) {}
                handler.postDelayed(this, BUCKET_CHECK_INTERVAL_MS)
            }
        }
        handler.post(bucketRunnable!!)
    }

    private fun stopBucketMonitoring() {
        try {
            bucketRunnable?.let { handler.removeCallbacks(it) }
            bucketRunnable = null
        } catch (_: Exception) {}
    }

    private fun bucketName(bucket: Int): String = when (bucket) {
        5 -> "EXEMPTED" // STANDBY_BUCKET_EXEMPTED (API 31+), best possible bucket
        UsageStatsManager.STANDBY_BUCKET_ACTIVE -> "ACTIVE"
        UsageStatsManager.STANDBY_BUCKET_WORKING_SET -> "WORKING_SET"
        UsageStatsManager.STANDBY_BUCKET_FREQUENT -> "FREQUENT"
        UsageStatsManager.STANDBY_BUCKET_RARE -> "RARE"
        UsageStatsManager.STANDBY_BUCKET_RESTRICTED -> "RESTRICTED"
        else -> "UNKNOWN($bucket)"
    }

    // --- Event dispatch ---

    private fun sendEvent(json: JSONObject) {
        handler.post {
            try {
                eventSink?.success(json.toString())
            } catch (_: Exception) {}
        }
    }
}

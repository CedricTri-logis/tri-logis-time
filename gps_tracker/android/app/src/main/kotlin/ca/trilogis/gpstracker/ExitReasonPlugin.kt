package ca.trilogis.gpstracker

import android.app.ActivityManager
import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel

class ExitReasonPlugin(private val context: Context) {

    companion object {
        private const val CHANNEL = "gps_tracker/exit_reason"
        private const val PREFS_NAME = "exit_reason_prefs"
        private const val KEY_LAST_COLLECTED_TS = "exit_reason_last_collected_ts"
        private const val MAX_RESULTS = 30

        fun register(messenger: BinaryMessenger, context: Context) {
            val plugin = ExitReasonPlugin(context)
            plugin.setupChannel(messenger)
        }
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun setupChannel(messenger: BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "getExitReasons" -> {
                    result.success(getExitReasons())
                }
                "updateProcessState" -> {
                    val jsonString = call.argument<String>("state") ?: ""
                    updateProcessState(jsonString)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * Read ApplicationExitInfo entries since last collection.
     * Returns a list of maps, each describing one exit event.
     * Returns empty list on API < 30.
     */
    private fun getExitReasons(): List<Map<String, Any?>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            return emptyList()
        }

        return try {
            val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
            val exitInfos = am.getHistoricalProcessExitReasons(
                context.packageName, 0, MAX_RESULTS
            )

            val lastCollectedTs = prefs.getLong(KEY_LAST_COLLECTED_TS, 0L)
            var maxTimestamp = lastCollectedTs

            val results = mutableListOf<Map<String, Any?>>()

            for (info in exitInfos) {
                if (info.timestamp <= lastCollectedTs) continue

                if (info.timestamp > maxTimestamp) {
                    maxTimestamp = info.timestamp
                }

                val stateBytes = try {
                    info.processStateSummary
                } catch (_: Exception) {
                    null
                }

                results.add(mapOf(
                    "reason" to reasonToString(info.reason),
                    "reason_code" to info.reason,
                    "timestamp" to info.timestamp,
                    "description" to (info.description ?: ""),
                    "importance" to importanceToString(info.importance),
                    "importance_code" to info.importance,
                    "pss_kb" to info.pss,
                    "rss_kb" to info.rss,
                    "status" to info.status,
                    "process_state_summary" to stateBytes?.let { String(it) }
                ))
            }

            // Save the most recent timestamp for deduplication
            if (maxTimestamp > lastCollectedTs) {
                prefs.edit().putLong(KEY_LAST_COLLECTED_TS, maxTimestamp).apply()
            }

            results
        } catch (e: Exception) {
            android.util.Log.e("ExitReasonPlugin", "Failed to get exit reasons", e)
            emptyList()
        }
    }

    /**
     * Write custom state blob via setProcessStateSummary().
     * The OS preserves this data across process kills.
     * Limit: 128 bytes. Caller must send compact JSON.
     */
    private fun updateProcessState(jsonString: String) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return

        try {
            val bytes = jsonString.toByteArray(Charsets.UTF_8)
            if (bytes.size > 128) {
                android.util.Log.w(
                    "ExitReasonPlugin",
                    "Process state too large (${bytes.size} bytes > 128), truncating"
                )
                val truncated = jsonString.toByteArray(Charsets.UTF_8).copyOf(128)
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                am.setProcessStateSummary(truncated)
            } else {
                val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
                am.setProcessStateSummary(bytes)
            }
        } catch (e: Exception) {
            android.util.Log.e("ExitReasonPlugin", "Failed to update process state", e)
        }
    }

    private fun reasonToString(reason: Int): String = when (reason) {
        0 -> "unknown"
        1 -> "exit_self"
        2 -> "signaled"
        3 -> "low_memory"
        4 -> "crash"
        5 -> "crash_native"
        6 -> "anr"
        7 -> "initialization_failure"
        8 -> "permission_change"
        9 -> "excessive_resource_usage"
        10 -> "user_requested"
        11 -> "user_stopped"
        12 -> "dependency_died"
        13 -> "other"
        14 -> "freezer"
        15 -> "package_state_change"
        16 -> "package_updated"
        else -> "unknown_$reason"
    }

    private fun importanceToString(importance: Int): String = when {
        importance <= 100 -> "foreground"
        importance <= 125 -> "foreground_service"
        importance <= 150 -> "visible"
        importance <= 200 -> "service"
        importance <= 300 -> "top_sleeping"
        importance <= 325 -> "cant_save_state"
        importance <= 400 -> "cached"
        importance <= 1000 -> "gone"
        else -> "unknown_$importance"
    }
}

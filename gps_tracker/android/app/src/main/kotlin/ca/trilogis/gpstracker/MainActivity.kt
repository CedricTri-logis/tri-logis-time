package ca.trilogis.gpstracker

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private var thermalStreamHandler: ThermalStreamHandler? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // --- Device Manufacturer Channel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gps_tracker/device_manufacturer")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getManufacturer" -> {
                        result.success(Build.MANUFACTURER.lowercase())
                    }
                    "openOemBatterySettings" -> {
                        val manufacturer = call.argument<String>("manufacturer") ?: ""
                        val opened = openOemBatterySettings(manufacturer)
                        result.success(opened)
                    }
                    else -> result.notImplemented()
                }
            }

        // --- Thermal State Method Channel ---
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "gps_tracker/thermal")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getThermalStatus" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                            result.success(powerManager.currentThermalStatus)
                        } else {
                            result.success(0) // THERMAL_STATUS_NONE on older devices
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // --- Thermal State Event Channel (stream) ---
        val thermalEventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "gps_tracker/thermal/stream"
        )
        thermalStreamHandler = ThermalStreamHandler(this)
        thermalEventChannel.setStreamHandler(thermalStreamHandler)
    }

    override fun onDestroy() {
        thermalStreamHandler?.cleanup()
        super.onDestroy()
    }

    /**
     * Try a chain of manufacturer-specific intents to open battery/autostart settings.
     * Returns true if any intent was successfully launched.
     */
    private fun openOemBatterySettings(manufacturer: String): Boolean {
        val intents = when (manufacturer.lowercase()) {
            "samsung" -> listOf(
                Intent().setComponent(ComponentName(
                    "com.samsung.android.lool",
                    "com.samsung.android.lool.BatteryActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.samsung.android.sm",
                    "com.samsung.android.sm.ui.battery.BatteryActivity"
                )),
                Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            )
            "xiaomi" -> listOf(
                Intent().setComponent(ComponentName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )),
                Intent("miui.intent.action.OP_AUTO_START"),
                Intent(Settings.ACTION_BATTERY_SAVER_SETTINGS)
            )
            "huawei" -> listOf(
                Intent().setComponent(ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.optimize.process.ProtectActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.appcontrol.activity.StartupAppControlActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.huawei.systemmanager",
                    "com.huawei.systemmanager.power.ui.HwPowerManagerActivity"
                ))
            )
            "oneplus", "oppo", "realme" -> listOf(
                Intent().setComponent(ComponentName(
                    "com.oneplus.security",
                    "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.coloros.safecenter",
                    "com.coloros.safecenter.startupapp.StartupAppListActivity"
                )),
                Intent().setComponent(ComponentName(
                    "com.oppo.safe",
                    "com.oppo.safe.permission.startup.StartupAppListActivity"
                ))
            )
            else -> return false
        }

        for (intent in intents) {
            try {
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(intent)
                return true
            } catch (_: Exception) {
                // Intent not resolved — try next
            }
        }
        return false
    }

    /**
     * EventChannel handler for streaming thermal status changes.
     */
    private class ThermalStreamHandler(
        private val activity: MainActivity
    ) : EventChannel.StreamHandler {

        private var listener: PowerManager.OnThermalStatusChangedListener? = null

        override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && events != null) {
                val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                listener = PowerManager.OnThermalStatusChangedListener { status ->
                    activity.runOnUiThread {
                        events.success(status)
                    }
                }
                powerManager.addThermalStatusListener(listener!!)
            }
        }

        override fun onCancel(arguments: Any?) {
            cleanup()
        }

        fun cleanup() {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                listener?.let {
                    val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
                    powerManager.removeThermalStatusListener(it)
                }
                listener = null
            }
        }
    }
}

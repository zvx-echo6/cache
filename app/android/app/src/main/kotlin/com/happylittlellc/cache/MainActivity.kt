package com.happylittlellc.cache

import android.Manifest
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.Context
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var pending: MethodChannel.Result? = null
    private var pendingNotifications: MethodChannel.Result? = null

    // Recent Android versions let the user switch network access (INTERNET) off, and an app updated from a build
    // that never asked for it does not get it; opening even the map's tile server port on this phone then fails.
    // The map screen asks through this channel when that happens.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/network_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        if (pending != null) {
                            result.success(false)
                        } else {
                            pending = result
                            requestPermissions(arrayOf(Manifest.permission.INTERNET), REQUEST_CODE)
                        }
                    }
                    "notifications" -> {
                        // Android 13 and later: the guidance notification only shows once this is allowed.
                        if (Build.VERSION.SDK_INT < 33 || notificationsGranted()) {
                            result.success(true)
                        } else if (pendingNotifications != null) {
                            result.success(false)
                        } else {
                            pendingNotifications = result
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE_NOTIFICATIONS)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/battery")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(battery())
                    else -> result.notImplemented()
                }
            }
    }

    // Battery level and whether the phone is plugged in (lib/platform/battery.dart): long automatic work (search indexes)
    // waits for charging or enough battery. The sticky battery broadcast answers at once and needs no permission.
    private fun battery(): Map<String, Any> {
        val status: Intent? = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
        val level = status?.getIntExtra(BatteryManager.EXTRA_LEVEL, -1) ?: -1
        val scale = status?.getIntExtra(BatteryManager.EXTRA_SCALE, -1) ?: -1
        val plugged = status?.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) ?: 0
        val percent = if (level >= 0 && scale > 0) level * 100 / scale else -1
        val out = mutableMapOf<String, Any>("percent" to percent, "charging" to (plugged != 0), "thermal" to thermal())
        headroom()?.let { out["headroom"] = it }
        return out
    }

    // How warm the phone is (Android 10 and later): background index work eases off as it warms and pauses when severe.
    private fun thermal(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unknown"
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return "unknown"
        return when (pm.currentThermalStatus) {
            PowerManager.THERMAL_STATUS_NONE -> "nominal"
            PowerManager.THERMAL_STATUS_LIGHT -> "light"
            PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
            PowerManager.THERMAL_STATUS_SEVERE -> "severe"
            else -> "critical"
        }
    }

    // The thermal headroom over the next 10 seconds (Android 11 and later; 1.0 is where the phone throttles hard), null where
    // the phone does not give one.
    private fun headroom(): Double? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return null
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return null
        val h = pm.getThermalHeadroom(10)
        return if (h.isNaN()) null else h.toDouble()
    }

    private fun notificationsGranted() =
        checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    private fun granted() =
        checkSelfPermission(Manifest.permission.INTERNET) == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        if (code == REQUEST_CODE) {
            pending?.success(granted())
            pending = null
        }
        if (code == REQUEST_CODE_NOTIFICATIONS) {
            pendingNotifications?.success(Build.VERSION.SDK_INT < 33 || notificationsGranted())
            pendingNotifications = null
        }
    }

    companion object {
        private const val REQUEST_CODE = 4210
        private const val REQUEST_CODE_NOTIFICATIONS = 4211
    }
}

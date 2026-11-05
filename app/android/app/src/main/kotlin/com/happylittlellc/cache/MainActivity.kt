package com.happylittlellc.cache

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.content.Context
import android.os.BatteryManager
import android.os.Bundle
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var systemUiChannel: MethodChannel? = null
    private var systemBarsConfigured = false
    private var hideStatusBar = false
    private var keyboardVisible = false
    private val restoreSystemBars = Runnable { applySystemBars() }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Observe, but do not consume, the insets Flutter needs for safe areas and text input.
        ViewCompat.setOnApplyWindowInsetsListener(window.decorView) { view, insets ->
            val keyboardNow = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (keyboardVisible && !keyboardNow) {
                view.removeCallbacks(restoreSystemBars)
                // Android prevents hiding navigation for one second after text input ends.
                view.postDelayed(restoreSystemBars, 1100)
            }
            keyboardVisible = keyboardNow
            insets
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) window.decorView.post(restoreSystemBars)
    }

    private fun applySystemBars() {
        if (!systemBarsConfigured || keyboardVisible || isFinishing) return
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.navigationBars())
        if (hideStatusBar) controller.hide(WindowInsetsCompat.Type.statusBars())
        else controller.show(WindowInsetsCompat.Type.statusBars())
    }

    private var memoryChannel: MethodChannel? = null
    private var pending: MethodChannel.Result? = null
    private var pendingNotifications: MethodChannel.Result? = null

    // Recent Android versions let the user switch network access (INTERNET) off, and an app updated from a build
    // that never asked for it does not get it; opening even the map's tile server port on this phone then fails.
    // The map screen asks through this channel when that happens.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        systemUiChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/system_ui").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "apply" -> {
                        hideStatusBar = call.argument<Boolean>("hideStatusBar") == true
                        systemBarsConfigured = true
                        window.decorView.post(restoreSystemBars)
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }
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
        // The device's free memory (lib/platform/memory.dart): the model loads only when it fits what is free now, and is let go
        // when Android says memory is low.
        memoryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/memory").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "read" -> result.success(memory())
                    // The log's header: the phone's maker and model.
                    "device" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                    // The log: why the app's process ended the last times (Android 11 and later).
                    "exits" -> result.success(exits())
                    else -> result.notImplemented()
                }
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

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        window.decorView.removeCallbacks(restoreSystemBars)
        systemUiChannel?.setMethodCallHandler(null)
        systemUiChannel = null
        memoryChannel?.setMethodCallHandler(null)
        memoryChannel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun exits(): List<Map<String, Any>> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) return emptyList()
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return emptyList()
        return try {
            am.getHistoricalProcessExitReasons(packageName, 0, 8).map { e ->
                val reason = when (e.reason) {
                    android.app.ApplicationExitInfo.REASON_CRASH -> "crash"
                    android.app.ApplicationExitInfo.REASON_CRASH_NATIVE -> "native crash"
                    android.app.ApplicationExitInfo.REASON_ANR -> "not responding"
                    android.app.ApplicationExitInfo.REASON_LOW_MEMORY -> "low memory"
                    android.app.ApplicationExitInfo.REASON_EXIT_SELF -> "closed itself"
                    android.app.ApplicationExitInfo.REASON_SIGNALED -> "stopped by a signal"
                    android.app.ApplicationExitInfo.REASON_USER_REQUESTED -> "stopped by the user"
                    android.app.ApplicationExitInfo.REASON_USER_STOPPED -> "force stopped"
                    android.app.ApplicationExitInfo.REASON_OTHER -> "other"
                    else -> "reason ${e.reason}"
                }
                mapOf("time" to e.timestamp, "reason" to reason, "description" to (e.description ?: ""), "pss" to e.pss, "rss" to e.rss)
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    private fun memory(): Map<String, Any> {
        val am = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager ?: return emptyMap()
        val info = ActivityManager.MemoryInfo()
        am.getMemoryInfo(info)
        return mapOf("avail" to info.availMem, "total" to info.totalMem, "threshold" to info.threshold, "low" to info.lowMemory)
    }

    // Android's word that memory is short (the level, and the memory now): the app lets the model go when it is, so it is not
    // the one killed. Delivered on top of what Flutter does with it.
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        memoryChannel?.invokeMethod("trim", mapOf("level" to level) + memory())
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

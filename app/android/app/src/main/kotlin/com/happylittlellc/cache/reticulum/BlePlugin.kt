package com.happylittlellc.cache.reticulum

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMethodCodec

/** Engine-owned Bluetooth adapter. Permission UI needs an activity; the adapter itself holds only application context. */
class BlePlugin : FlutterPlugin, ActivityAware, MethodChannel.MethodCallHandler {
    @Volatile private var context: Context? = null
    @Volatile private var activity: Activity? = null
    private var channel: MethodChannel? = null
    @Volatile private var sessions: BleSessionController? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val app = binding.applicationContext
        context = app
        sessions = BleSessionController { handle ->
            val bridge = NativeBridge(handle)
            check(bridge.nativeBlePeerCapacity() > 0) { "Bluetooth session expired" }
            val link = BleLink(app, bridge)
            try {
                link.start()
            } catch (e: Throwable) {
                try { link.stop() } catch (cleanup: Throwable) { e.addSuppressed(cleanup) }
                throw e
            }
            object : BleAdapterSession {
                override val alive get() = bridge.nativeBlePeerCapacity() > 0
                override val active get() = link.isRadioActive()
                override fun stop() = link.stop()
            }
        }
        channel = MethodChannel(binding.binaryMessenger, "co.cache/bluetooth", StandardMethodCodec.INSTANCE,
            binding.binaryMessenger.makeBackgroundTaskQueue()).also { it.setMethodCallHandler(this) }
    }

    private fun missingPermissions(app: Context): List<String> {
        val required = if (Build.VERSION.SDK_INT >= 31) listOf(
            Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT, Manifest.permission.BLUETOOTH_ADVERTISE,
        ) else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        return required.filter { app.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED }
    }

    private fun status(): Map<String, Any?> {
        val app = checkNotNull(context)
        val supported = app.packageManager.hasSystemFeature(PackageManager.FEATURE_BLUETOOTH_LE)
        val missing = missingPermissions(app)
        val enabled = supported && missing.isEmpty() &&
            ((app.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter?.isEnabled == true)
        if (!enabled) sessions?.stop()
        val (handle, active) = sessions?.snapshot() ?: (null to false)
        return mapOf("supported" to supported, "missing_permissions" to missing, "enabled" to enabled,
            "handle" to handle, "active" to active)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "status" -> result.success(status())
                "request_permissions" -> {
                    val app = checkNotNull(context)
                    val missing = missingPermissions(app)
                    if (missing.isNotEmpty()) {
                        val screen = activity ?: error("Open Cache to allow Bluetooth")
                        screen.runOnUiThread {
                            try {
                                check(!screen.isFinishing && !screen.isDestroyed) { "Open Cache to allow Bluetooth" }
                                val asked = app.getSharedPreferences("cache_bluetooth_permissions", Context.MODE_PRIVATE)
                                val settingsNeeded = missing.any { asked.getBoolean(it, false) && !screen.shouldShowRequestPermissionRationale(it) }
                                if (settingsNeeded) {
                                    screen.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${app.packageName}")))
                                } else {
                                    asked.edit().also { edit -> missing.forEach { edit.putBoolean(it, true) } }.apply()
                                    screen.requestPermissions(missing.toTypedArray(), 0xCA6E)
                                }
                                result.success(status())
                            } catch (e: Throwable) {
                                result.error("bluetooth", e.message ?: "Bluetooth permission could not be requested", null)
                            }
                        }
                    } else {
                        result.success(status())
                    }
                }
                "start" -> {
                    val state = status()
                    check(state["enabled"] == true) { "Bluetooth permission and an enabled adapter are required" }
                    val handle = call.argument<Number>("handle")?.toLong() ?: error("Bluetooth session handle is required")
                    checkNotNull(sessions).start(handle)
                    result.success(status())
                }
                "stop" -> { sessions?.stop(call.argument<Number>("handle")?.toLong()); result.success(status()) }
                else -> result.notImplemented()
            }
        } catch (e: Throwable) {
            result.error("bluetooth", e.message ?: "Bluetooth could not start", null)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        try { sessions?.close() } finally { sessions = null; activity = null; context = null }
    }
    override fun onAttachedToActivity(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) { activity = binding.activity }
    override fun onDetachedFromActivityForConfigChanges() { activity = null }
    override fun onDetachedFromActivity() { activity = null }
}

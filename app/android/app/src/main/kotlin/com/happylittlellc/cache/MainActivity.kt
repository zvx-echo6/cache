package com.happylittlellc.cache

import android.Manifest
import android.app.ActivityManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.Context
import android.os.Bundle
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.happylittlellc.cache.car.SharedEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var systemUiChannel: MethodChannel? = null
    private var systemBarsConfigured = false
    private var hideStatusBar = false
    private var keyboardVisible = false
    private val restoreSystemBars = Runnable { applySystemBars() }

    // Test APK only (BuildConfig.TEST_APK): the bench's launch extra, read by Dart through the cache/bench channel. In the release
    // build nothing is read and the channel answers zeros.
    private var benchPrereadMbps: Int? = null  // null: the extra was not given (the app's default applies)
    private var benchDateOffsetDays: Int? = null  // cache_date_offset_days: shifts the system prompt's date line only
    private var benchEmbedThreads: Int? = null  // cache_embed_threads: the search model's thread count (measurement)
    private var benchPoolPause: Boolean? = null  // cache_pool_pause: rest the chat threadpool while nothing decodes (measurement)
    private var benchPoolPoll: Int? = null  // cache_pool_poll: the chat threadpool's poll level (measurement)
    private var benchDeferSearchLoad: Boolean? = null  // cache_defer_search_load: Ask's open loads the search model after the read ahead (measurement)
    private var benchUbatch: Int? = null  // cache_ubatch: the chat context's n_ubatch (measurement)

    private fun readBenchExtras(i: Intent?) {
        if (!BuildConfig.TEST_APK || i == null) return
        if (i.hasExtra("cache_preread_mbps")) benchPrereadMbps = i.getIntExtra("cache_preread_mbps", 0)
        if (i.hasExtra("cache_date_offset_days")) benchDateOffsetDays = i.getIntExtra("cache_date_offset_days", 0)
        if (i.hasExtra("cache_embed_threads")) benchEmbedThreads = i.getIntExtra("cache_embed_threads", 0)
        if (i.hasExtra("cache_pool_pause")) benchPoolPause = i.getBooleanExtra("cache_pool_pause", false)
        if (i.hasExtra("cache_pool_poll")) benchPoolPoll = i.getIntExtra("cache_pool_poll", 0)
        if (i.hasExtra("cache_defer_search_load")) benchDeferSearchLoad = i.getBooleanExtra("cache_defer_search_load", false)
        if (i.hasExtra("cache_ubatch")) benchUbatch = i.getIntExtra("cache_ubatch", 0)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        readBenchExtras(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        SharedEngine.activityStarted()
        super.onCreate(savedInstanceState)
        readBenchExtras(intent)
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

    // One engine for the phone screen and the car screen (Android Auto, see car/SharedEngine.kt): guidance runs once, in Dart.
    // With no car the engine still goes with the activity, as before.
    override fun provideFlutterEngine(context: Context): FlutterEngine = SharedEngine.obtain(context)

    override fun shouldDestroyEngineWithHost(): Boolean = SharedEngine.releaseFromActivity()

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
    private var routeSnapshot: RouteSnapshot? = null
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
                    // Turn-by-turn guidance keeps the screen on (lib/nav/guidance_wakelock.dart). The flag only holds while
                    // this window is shown, so the background lets the screen sleep as usual.
                    "keepScreenOn" -> {
                        if (call.argument<Boolean>("on") == true) {
                            window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        } else {
                            window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        }
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
        // The bench's options (test APK only; nothing in the release build).
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cache/bench")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Only what was given: no "preread_mbps" key when the extra is absent, and never in the release build.
                    "get" -> {
                        val out = mutableMapOf<String, Any>("testApk" to BuildConfig.TEST_APK)
                        val mbps = benchPrereadMbps
                        if (BuildConfig.TEST_APK && mbps != null) out["preread_mbps"] = mbps
                        val days = benchDateOffsetDays
                        if (BuildConfig.TEST_APK && days != null) out["date_offset_days"] = days
                        val ub = benchUbatch
                        if (BuildConfig.TEST_APK && ub != null) out["cache_ubatch"] = ub
                        val et = benchEmbedThreads
                        if (BuildConfig.TEST_APK && et != null) out["cache_embed_threads"] = et
                        val pp = benchPoolPause
                        if (BuildConfig.TEST_APK && pp != null) out["cache_pool_pause"] = pp
                        val pl = benchPoolPoll
                        if (BuildConfig.TEST_APK && pl != null) out["cache_pool_poll"] = pl
                        val ds = benchDeferSearchLoad
                        if (BuildConfig.TEST_APK && ds != null) out["cache_defer_search_load"] = ds
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }
        // The whole-route picture during guidance (RouteSnapshot.kt).
        routeSnapshot = RouteSnapshot(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        window.decorView.removeCallbacks(restoreSystemBars)
        systemUiChannel?.setMethodCallHandler(null)
        systemUiChannel = null
        memoryChannel?.setMethodCallHandler(null)
        memoryChannel = null
        // The engine can outlive this activity while the car screen uses it: let go of the handlers that need the activity.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/network_access").setMethodCallHandler(null)
        routeSnapshot?.dispose()
        routeSnapshot = null
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
                    // numbers from the ApplicationExitInfo reference (these two are API 34; the app's compileSdk may predate them)
                    8 -> "permission changed"
                    15 -> "app changed"
                    16 -> "app updated"
                    else -> "reason ${e.reason}"
                }
                mapOf("time" to e.timestamp, "reason" to reason, "code" to e.reason, "description" to (e.description ?: ""), "pss" to e.pss, "rss" to e.rss)
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

    // Battery and heat (co.cache/battery) are answered by the cache_device plugin, in every engine.

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

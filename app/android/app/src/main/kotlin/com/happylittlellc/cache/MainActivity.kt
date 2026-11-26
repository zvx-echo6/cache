package com.happylittlellc.cache

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.app.KeyguardManager
import android.content.Intent
import android.content.pm.PackageManager
import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import com.happylittlellc.cache.car.GeoView
import com.happylittlellc.cache.car.NavIntent
import com.happylittlellc.cache.car.SharedEngine
import com.happylittlellc.cache.fgs.FgsAddArm
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
    private var benchUbatch: Int? = null  // cache_ubatch: the chat context's n_ubatch (measurement)

    private fun readBenchExtras(i: Intent?) {
        if (!BuildConfig.TEST_APK || i == null) return
        if (i.hasExtra("cache_preread_mbps")) benchPrereadMbps = i.getIntExtra("cache_preread_mbps", 0)
        if (i.hasExtra("cache_date_offset_days")) benchDateOffsetDays = i.getIntExtra("cache_date_offset_days", 0)
        if (i.hasExtra("cache_embed_threads")) benchEmbedThreads = i.getIntExtra("cache_embed_threads", 0)
        if (i.hasExtra("cache_ubatch")) benchUbatch = i.getIntExtra("cache_ubatch", 0)
    }

    // A cachelink: link (a camera scanning a device's link code). Held until Dart takes it (a cold start: the link arrives before
    // Dart listens) and also pushed to a running Dart on the co.cache/link channel. Flutter's own deep-link routing is off
    // (flutter_deeplinking_enabled in the manifest), so the link never becomes a route.
    private var linkChannel: MethodChannel? = null
    private var pendingLink: String? = null

    private fun readLink(i: Intent?) {
        if (i == null || i.action != Intent.ACTION_VIEW) return
        // An activity brought back from the Recents list repeats the intent it was first started with; that is not a new link.
        if ((i.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0) return
        val uri = i.data ?: return
        if (!"cachelink".equals(uri.scheme, ignoreCase = true)) return
        val link = i.dataString ?: return
        // Cleared so a re-created activity does not deliver the same link again.
        i.data = null
        pendingLink = link
        linkChannel?.invokeMethod("opened", link, object : MethodChannel.Result {
            override fun success(result: Any?) { if (pendingLink == link) pendingLink = null }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    // A tap on a guidance notification (OpenMaps.kt): the Maps tab. Held until Dart takes it (a cold start) and also pushed to a
    // running Dart on the co.cache/open channel (lib/nav/open_maps.dart).
    private var openChannel: MethodChannel? = null
    private var pendingOpen: Any? = null  // "maps", or a map (what, lat, lon, query) for a geo: link opened here

    private fun readOpen(i: Intent?) {
        if (!OpenMaps.wants(i)) return
        // Cleared so a re-created activity does not open the Maps tab again.
        i!!.removeExtra(OpenMaps.EXTRA)
        pendingOpen = OpenMaps.MAPS
        openChannel?.invokeMethod("open", OpenMaps.MAPS, object : MethodChannel.Result {
            override fun success(result: Any?) { pendingOpen = null }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    // A geo: link with no car connected (Cache picked from "Open with"): the Maps tab, with the search or the point. Held until
    // Dart takes it, and pushed to a running Dart on the co.cache/open channel.
    private fun openGeo(v: GeoView) {
        val (lat, lon, query) = when (v) {
            is GeoView.Search -> Triple(v.lat, v.lon, v.query)
            is GeoView.Point -> Triple(v.req.lat, v.req.lon, v.req.query)
        }
        val what = hashMapOf<String, Any?>("what" to OpenMaps.MAPS, "lat" to lat, "lon" to lon, "query" to query)
        pendingOpen = what
        openChannel?.invokeMethod("open", what, object : MethodChannel.Result {
            override fun success(result: Any?) { pendingOpen = null }
            override fun error(code: String, message: String?, details: Any?) {}
            override fun notImplemented() {}
        })
    }

    override fun onNewIntent(intent: Intent) {
        // A navigation request (Android Auto's NAVIGATE with a "geo:" address; the filter is on this activity because Android
        // Auto asks for it there, src/car/AndroidManifest.xml): the car session takes it when a car is connected, otherwise it
        // is dropped. Flutter never sees it: it would read the address as a page to open, and the app has no such pages.
        if (NavIntent.fromPhone(intent, ::openGeo)) return
        super.onNewIntent(intent)
        readBenchExtras(intent)
        readLink(intent)
        readOpen(intent)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        SharedEngine.activityStarted()
        // The same when the request is what started this activity: the app opens as from its icon.
        if (NavIntent.fromPhone(intent, ::openGeo)) intent = NavIntent.plainLaunch(intent)
        super.onCreate(savedInstanceState)
        readBenchExtras(intent)
        readLink(intent)
        readOpen(intent)
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
    override fun provideFlutterEngine(context: Context): FlutterEngine = SharedEngine.obtain(context)

    // The engine never goes with this activity: it is kept for the life of the process, and the next phone screen or car
    // session attaches to the same running app (car/SharedEngine.kt says why). Flutter asks this more than once, so it only
    // answers; cleanUpFlutterEngine tells the engine's keeper that this screen has let go.
    override fun shouldDestroyEngineWithHost(): Boolean = false

    // Leaving with adds pending starts the foreground service that carries them on (fgs/FgsAddArm.kt). Home comes here; Back at the
    // root finishes the activity (onPause sees it); the app switcher (Recents) may give only a pause, so a pause that does not get
    // its window focus back soon counts; and the stop is the last chance. All while Cache is still just leaving, as Android 12 requires.
    private val leaveCheck = Runnable { if (!hasWindowFocus() && !isFinishing) FgsAddArm.onLeave(this, FgsAddArm.Leave.PAUSED) }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        FgsAddArm.onLeave(this, FgsAddArm.Leave.HINT)
    }

    override fun onPause() {
        super.onPause()
        if (isFinishing) FgsAddArm.onLeave(this, FgsAddArm.Leave.HINT) else window.decorView.postDelayed(leaveCheck, 1500)
    }

    override fun onResume() {
        super.onResume()
        window.decorView.removeCallbacks(leaveCheck)
        FgsAddArm.resumed()
    }

    override fun onStop() {
        super.onStop()
        FgsAddArm.onLeave(this, FgsAddArm.Leave.STOP)
    }

    // The app's own launches (the file picker, a permission prompt) make a leave hint that is not the person leaving.
    override fun startActivityForResult(intent: Intent, requestCode: Int, options: Bundle?) {
        FgsAddArm.noteInternalLaunch()
        super.startActivityForResult(intent, requestCode, options)
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
    private var routeSnapshot: RouteSnapshot? = null
    private var pending: MethodChannel.Result? = null
    private var pendingNotifications: MethodChannel.Result? = null
    private var pendingLock: MethodChannel.Result? = null

    // Recent Android versions let the user switch network access (INTERNET) off, and an app updated from a build
    // that never asked for it does not get it; opening even the map's tile server port on this phone then fails.
    // The map screen asks through this channel when that happens.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        linkChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/link").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        val link = pendingLink
                        pendingLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }
        }
        openChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/open").also {
            it.setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        val open = pendingOpen
                        pendingOpen = null
                        result.success(open)
                    }
                    else -> result.notImplemented()
                }
            }
            // A request this activity was (re)created with while Dart already runs (the shared engine: Dart took at its own start,
            // not now): pushed as well. Dart not listening yet answers notImplemented and the request stays for its take.
            pendingOpen?.let { open ->
                it.invokeMethod("open", open, object : MethodChannel.Result {
                    override fun success(result: Any?) { if (pendingOpen === open) pendingOpen = null }
                    override fun error(code: String, message: String?, details: Any?) {}
                    override fun notImplemented() {}
                })
            }
        }
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
        // The phone's own screen lock, asked before a device is unlinked (lib/platform/device_lock.dart): "ok", "cancelled", or
        // "none" when no lock is set. The system's confirm-credential screen, so no extra package.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/device_lock")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "confirm" -> confirmDeviceLock(call.argument<String>("title"), call.argument<String>("description"), result)
                    else -> result.notImplemented()
                }
            }
        FgsAddArm.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        // The Wi-Fi multicast lock: Android drops multicast packets unless an app holds one, and Reticulum's local discovery
        // (sharing_state.dart) needs them. Taken just before the sharing engine opens and let go when it stops.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/multicast")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "acquire" -> {
                        try {
                            acquireMulticast()
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "release" -> {
                        releaseMulticast()
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
        CprBeat.attach(this, flutterEngine.dartExecutor.binaryMessenger)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/network_access")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "request" -> {
                        if (pending != null) {
                            result.success(false)
                        } else {
                            pending = result
                            FgsAddArm.noteInternalLaunch()
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
                            FgsAddArm.noteInternalLaunch()
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), REQUEST_CODE_NOTIFICATIONS)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // The device's free memory (lib/platform/memory.dart): the model loads only when it fits what is free now, and is let go
        // when Android says memory is low.
        // The memory channel is answered by the engine (MemoryAnswers, set in car/SharedEngine.kt); this screen only sends the
        // system's "trim" on it.
        memoryChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MemoryAnswers.CHANNEL)
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
                        result.success(out)
                    }
                    else -> result.notImplemented()
                }
            }
        // What this build was made with (cache/build) is answered by the engine itself, with or without this activity
        // (car/SharedEngine.kt).
        // The whole-route picture during guidance (RouteSnapshot.kt).
        routeSnapshot = RouteSnapshot(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        window.decorView.removeCallbacks(restoreSystemBars)
        systemUiChannel?.setMethodCallHandler(null)
        systemUiChannel = null
        memoryChannel = null
        // The engine outlives this activity: let go of the handlers that need the activity (the next one sets its own).
        linkChannel?.setMethodCallHandler(null)
        linkChannel = null
        openChannel?.setMethodCallHandler(null)
        openChannel = null
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cache/bench").setMethodCallHandler(null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/network_access").setMethodCallHandler(null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/multicast").setMethodCallHandler(null)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "co.cache/device_lock").setMethodCallHandler(null)
        pendingLock?.success("cancelled")
        pendingLock = null
        FgsAddArm.detach(flutterEngine.dartExecutor.binaryMessenger)
        CprBeat.detach(this, flutterEngine.dartExecutor.binaryMessenger)
        routeSnapshot?.dispose()
        routeSnapshot = null
        super.cleanUpFlutterEngine(flutterEngine)
        SharedEngine.activityEnded()
    }

    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticast() {
        val held = multicastLock
        if (held != null && held.isHeld) return
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        val lock = wifi.createMulticastLock("cache-rns")
        lock.setReferenceCounted(false)
        lock.acquire()
        multicastLock = lock
    }

    private fun releaseMulticast() {
        val held = multicastLock
        if (held != null && held.isHeld) held.release()
        multicastLock = null
    }

    // A backstop: the lock never outlives the screen that took it.
    override fun onDestroy() {
        releaseMulticast()
        super.onDestroy()
    }

    // Android's word that memory is short (the level, and the memory now): the app lets the model go when it is, so it is not
    // the one killed. Delivered on top of what Flutter does with it.
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        memoryChannel?.invokeMethod("trim", mapOf("level" to level) + MemoryAnswers.memory(this))
    }

    // Battery and heat (co.cache/battery) are answered by the cache_device plugin, in every engine.

    @Suppress("DEPRECATION") // the intent still works on every API; androidx.biometric is not in this app, and none is added
    private fun confirmDeviceLock(title: String?, description: String?, result: MethodChannel.Result) {
        if (pendingLock != null) {
            result.success("cancelled")
            return
        }
        val keyguard = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
        val intent = if (keyguard.isDeviceSecure) keyguard.createConfirmDeviceCredentialIntent(title, description) else null
        if (intent == null) {
            result.success("none")
            return
        }
        pendingLock = result
        // startActivityForResult below already tells FgsAddArm this leave is the app's own.
        @Suppress("DEPRECATION")
        startActivityForResult(intent, REQUEST_CODE_LOCK)
    }

    @Suppress("DEPRECATION")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_LOCK) {
            pendingLock?.success(if (resultCode == Activity.RESULT_OK) "ok" else "cancelled")
            pendingLock = null
        }
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
        private const val REQUEST_CODE_LOCK = 4212
    }
}

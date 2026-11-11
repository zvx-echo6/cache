package com.happylittlellc.cache.car

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.happylittlellc.cache.BuildConfig

/**
 * The app's one Flutter engine, shared by the phone screen (MainActivity) and the car screen (CacheCarAppService).
 *
 * Guidance lives in Dart (NavState), once. When the car starts Cache with the phone app closed, the car session starts the
 * engine here and runs the app's normal `main`; when the phone app opens later it attaches to that same engine. When the phone
 * app opens first, the car uses its engine. Without a car the phone behaves exactly as before: the engine goes when the activity
 * goes ([releaseFromActivity] says so).
 */
object SharedEngine {
    const val ID = "cache_main"

    private var activityAttached = false
    private var carSessions = 0

    /** The engine, made and started on first use. Main thread only. */
    fun obtain(context: Context): FlutterEngine {
        FlutterEngineCache.getInstance().get(ID)?.let { return it }
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        CarLink.attach(engine)
        answerBuild(engine.dartExecutor.binaryMessenger)
        return engine
    }

    /**
     * What this build was made with, on the `cache/build` channel (lib/car/car_support.dart: Settings shows its Car group only
     * when androidAuto is true). Dart asks once, at start, so the answer is set on the engine as it is made and needs no
     * activity: when the car starts the app there is none, and the question used to go unanswered.
     */
    internal fun answerBuild(messenger: BinaryMessenger) {
        MethodChannel(messenger, "cache/build").setMethodCallHandler { call, result ->
            when (call.method) {
                "get" -> result.success(mapOf("androidAuto" to BuildConfig.CACHE_ANDROID_AUTO))
                else -> result.notImplemented()
            }
        }
    }

    fun activityStarted() {
        activityAttached = true
    }

    /**
     * The activity is going. True when the engine should go with it (no car session needs it): it is then taken out of the
     * cache, and the activity destroys it as it always did.
     */
    fun releaseFromActivity(): Boolean {
        activityAttached = false
        if (carSessions > 0) return false
        drop()
        return true
    }

    fun carStarted() {
        carSessions++
    }

    /** A car session ended: with no activity either, nothing needs the engine any more. */
    fun carEnded() {
        carSessions = (carSessions - 1).coerceAtLeast(0)
        if (carSessions == 0 && !activityAttached) {
            val engine = FlutterEngineCache.getInstance().get(ID)
            drop()
            engine?.destroy()
        }
    }

    val carInUse: Boolean get() = carSessions > 0

    private fun drop() {
        FlutterEngineCache.getInstance().remove(ID)
        CarLink.detach()
    }
}

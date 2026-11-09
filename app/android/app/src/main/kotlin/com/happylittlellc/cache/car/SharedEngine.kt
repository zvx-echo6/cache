package com.happylittlellc.cache.car

import android.content.Context
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor

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
        return engine
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

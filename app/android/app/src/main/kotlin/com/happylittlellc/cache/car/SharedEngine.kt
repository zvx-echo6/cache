package com.happylittlellc.cache.car

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import com.happylittlellc.cache.BuildConfig
import com.happylittlellc.cache.MemoryAnswers

/**
 * The app's one Flutter engine, shared by the phone screen (MainActivity) and the car screen (CacheCarAppService) and kept for
 * the life of the process.
 *
 * Guidance lives in Dart (NavState), once. Whoever needs the engine first makes it and runs the app's normal `main`: the phone
 * screen, or the car session when the car starts Cache with the phone app closed. Every phone screen and car session after
 * that attaches to the same engine and the same running app.
 *
 * The engine is never destroyed: not when a car session ends, and not when the phone's activity goes. Destroying it ended only
 * Dart's main isolate. The app's worker isolates, the search core with its router and tile server threads, the sync engine, a
 * loaded model and the engine's graphics memory all stayed, and the next car session or phone screen made a new engine and ran
 * `main` again beside them: more memory with every car session, several sync engines working on the same folders, and a
 * "stopped unexpectedly" line in the log at every start. See [EngineLife].
 */
object SharedEngine {
    const val ID = "cache_main"

    private val life = EngineLife<FlutterEngine>(make = { start(it) })

    /** The engine for a phone screen: made and started on first use. Main thread only. */
    fun obtain(context: Context): FlutterEngine = life.obtain(context)

    /** A phone screen (activity) is being made on the engine. */
    fun activityStarted() = life.activityStarted()

    /** A phone screen has let go of the engine (it was closed, or another took its place). The engine stays. */
    fun activityEnded() = life.activityEnded()

    /** A car session starts: it gets the engine, made and started now when nothing made it before. Main thread only. */
    fun carStarted(context: Context): FlutterEngine = life.carStarted(context)

    /** A car session ended. The engine stays. */
    fun carEnded() = life.carEnded()

    private fun start(context: Context): FlutterEngine {
        val engine = FlutterEngine(context.applicationContext)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ID, engine)
        CarLink.attach(engine)
        answerBuild(engine.dartExecutor.binaryMessenger)
        MemoryAnswers.attach(engine.dartExecutor.binaryMessenger, context)
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
}

/**
 * The life of the app's engine: made once, by whoever needs it first, and kept until the process ends. Nothing here destroys
 * it or lets go of it.
 *
 * [make] makes and starts the engine; the tests give a stand-in (a real engine needs Flutter's native library).
 *
 * Nothing here speaks to the running app about its screens. A phone screen does that itself (Flutter's activity says resumed,
 * inactive, paused and detached as it comes and goes), and the car session says "connected" on its own channel ([CarLink]).
 * The car side must never use the engine's lifecycle channel for a session that has no phone screen: on Android an engine
 * starts in the state "detached", and whatever is sent after that, Flutter first reports as "resumed", which the app reads as
 * a phone screen coming to the front. (It was tried: "inactive, paused, detached" when the car that had started Cache left
 * made the app load its chat model.) What the app does when the car leaves and no phone screen is open is its own
 * (lib/main.dart).
 */
internal class EngineLife<E : Any>(
    private val make: (Context) -> E,
) {
    /** The engine, once made. */
    var engine: E? = null
        private set

    /** How many engines this process has made: none, then one for the rest of its life. */
    var made = 0
        private set

    private var activities = 0
    private var carSessions = 0

    fun obtain(context: Context): E = get(context, "the phone screen")

    private fun get(context: Context, who: String): E {
        engine?.let { return it }
        val e = make(context)
        engine = e
        made++
        Log.i(TAG, "the app engine was made for $who ($made in this process)")
        return e
    }

    fun activityStarted() {
        activities++
    }

    fun activityEnded() {
        activities = (activities - 1).coerceAtLeast(0)
        Log.i(TAG, "a phone screen closed: the app engine stays (phone screens $activities, car sessions $carSessions)")
    }

    fun carStarted(context: Context): E {
        val e = get(context, "the car")
        carSessions++
        return e
    }

    fun carEnded() {
        carSessions = (carSessions - 1).coerceAtLeast(0)
        Log.i(TAG, "a car session ended: the app engine stays (phone screens $activities, car sessions $carSessions)")
    }

    private companion object {
        const val TAG = "CacheEngine"
    }
}

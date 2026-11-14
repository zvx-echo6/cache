package com.happylittlellc.cache.fgs

import android.content.Context
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** What the run tells the service. Always on the main thread. */
interface FgsAddEvents {
    fun onProgress(p: FgsProgress)
    fun onFinished(f: FgsFinish)
}

/** The add itself: the Dart entry point. The service owns one; tests give a stand-in (a real engine needs Flutter's native library). */
interface FgsAddRunner {
    /** Starts the add. [resume] and [anyway]: the notification's Resume and Resume anyway started this run. */
    fun start(resume: Boolean, anyway: Boolean, events: FgsAddEvents)

    /** Asks the add to stop and keep what is done: [why] is "person" (Pause) or "timeout" (Android's time limit). */
    fun stop(why: String)

    /** Lets go of the engine, [afterMs] from now (a run asked to stop needs a moment to save). */
    fun release(afterMs: Long)
}

/**
 * The real runner: a Flutter engine of its own, in this process (the same arrangement as WorkManager's background engine), running
 * `cacheFgsAddEntry` (lib/background/background_dispatcher.dart), which runs the same Add PDF slice as the WorkManager charging
 * run, under the same `run-pdf-add` lock.
 */
class DartFgsAddRunner(private val context: Context) : FgsAddRunner {
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var pendingStop: String? = null
    private val main = Handler(Looper.getMainLooper())

    override fun start(resume: Boolean, anyway: Boolean, events: FgsAddEvents) {
        val e = FlutterEngine(context.applicationContext)
        engine = e
        val ch = MethodChannel(e.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                // Dart asks once, as it starts: what started this run, and a stop that came before it was listening
                "ready" -> result.success(mapOf("resume" to resume, "anyway" to anyway, "stop" to pendingStop))
                "progress" -> {
                    (call.arguments as? Map<*, *>)?.let { events.onProgress(FgsProgress.from(it)) }
                    result.success(null)
                }
                "finished" -> {
                    (call.arguments as? Map<*, *>)?.let { events.onFinished(FgsFinish.from(it)) }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        val bundle = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        e.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint(bundle, ENTRY_LIBRARY, ENTRY_FUNCTION))
    }

    override fun stop(why: String) {
        pendingStop = pendingStop ?: why
        channel?.invokeMethod("stop", mapOf("why" to why))
    }

    override fun release(afterMs: Long) {
        val e = engine ?: return
        engine = null
        main.postDelayed({
            channel?.setMethodCallHandler(null)
            channel = null
            e.destroy()
        }, afterMs)
    }

    companion object {
        const val CHANNEL = "co.cache/fgs_add_run"
        const val ENTRY_LIBRARY = "package:cache/background/background_dispatcher.dart"
        const val ENTRY_FUNCTION = "cacheFgsAddEntry"
    }
}

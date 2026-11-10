package com.happylittlellc.cache.litert

import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.InputData
import com.google.ai.edge.litertlm.ResponseCallback
import com.google.ai.edge.litertlm.SamplerConfig
import com.google.ai.edge.litertlm.Session
import com.google.ai.edge.litertlm.SessionConfig
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors

/**
 * A minimal LiteRT-LM chat engine for the Cache test APK (never in the Play build: this source set is compiled only with
 * -PcacheLiteRt=true). Dart renders the prompt (with the model's own Jinja template) and parses the output; this only prefills
 * text, decodes it and streams the chunks back. MainActivity finds this class by name (reflection), so the main source set
 * compiles without it.
 *
 * Channels: method channel "cache/litert" (load, generate, stop, unload) and event channel "cache/litert/stream".
 *
 * Prefix reuse: up to [MAX_CHECKPOINTS] checkpoints, each (prompt text, a Session that holds exactly that text in its KV cache).
 * A checkpoint is a clone() taken right after prefilling a prompt and before decoding it. A new prompt clones the longest
 * checkpoint whose text is a prefix of it and prefills only the rest.
 */
object LiteRtBridge {
    private const val TAG = "CacheLiteRt"
    private const val PREFS = "cache_litert"
    private const val KEY_BACKEND = "backend"
    private const val EXTRA_BACKEND = "cache_litert_backend"
    private const val MAX_CHECKPOINTS = 2

    // Gemma's recommended nucleus settings, used when a request gives only a temperature.
    private const val TOP_K = 64
    private const val TOP_P = 0.95

    private class Checkpoint(val text: String, val sampler: String, val session: Session)

    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "CacheLiteRt").apply { isDaemon = true } }
    private val main = Handler(Looper.getMainLooper())

    @Volatile private var sink: EventChannel.EventSink? = null
    @Volatile private var working: Session? = null
    @Volatile private var stopRequested = false
    private var engine: Engine? = null
    private val checkpoints = ArrayList<Checkpoint>()
    private var prefs: SharedPreferences? = null
    private var registered: BinaryMessenger? = null

    /** Called by MainActivity when the Flutter engine is configured. */
    @JvmStatic
    fun register(context: Context, messenger: BinaryMessenger) {
        if (registered === messenger) return
        registered = messenger
        prefs = context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        MethodChannel(messenger, "cache/litert").setMethodCallHandler { call, result ->
            when (call.method) {
                "load" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("bad_args", "no path", null)
                    } else {
                        val backend = call.argument<String>("backend") ?: prefs?.getString(KEY_BACKEND, "cpu") ?: "cpu"
                        val maxNum = call.argument<Int>("maxNumTokens") ?: 8192
                        val cacheDir = call.argument<String>("cacheDir")
                        worker.execute { load(path, backend, maxNum, cacheDir, result) }
                    }
                }
                "generate" -> {
                    val id = call.argument<Int>("id") ?: 0
                    val prompt = call.argument<String>("prompt")
                    if (prompt == null) {
                        result.error("bad_args", "no prompt", null)
                    } else {
                        val maxTokens = call.argument<Int>("maxTokens")
                        val temperature = call.argument<Double>("temperature")
                        stopRequested = false
                        worker.execute { generate(id, prompt, maxTokens, temperature) }
                        result.success(null)
                    }
                }
                "stop" -> {
                    stop()
                    result.success(null)
                }
                "unload" -> worker.execute {
                    unload()
                    main.post { result.success(null) }
                }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, "cache/litert/stream").setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                sink = events
            }

            override fun onCancel(arguments: Any?) {
                sink = null
            }
        })
    }

    /** Called by MainActivity for the launch intent and later ones: an extra chooses the backend for the next load. */
    @JvmStatic
    fun onIntent(context: Context, intent: Intent?) {
        val b = intent?.getStringExtra(EXTRA_BACKEND) ?: return
        if (b != "cpu" && b != "gpu") {
            Log.e(TAG, "backend extra '$b' ignored (cpu or gpu)")
            return
        }
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY_BACKEND, b).apply()
        Log.i(TAG, "backend for the next load: $b")
    }

    private fun emit(event: Map<String, Any?>) {
        main.post { sink?.success(event) }
    }

    private fun load(path: String, backendName: String, maxNum: Int, cacheDir: String?, result: MethodChannel.Result) {
        try {
            unload()
            val t0 = SystemClock.elapsedRealtime()
            val backend = if (backendName == "gpu") Backend.GPU() else Backend.CPU()
            val e = Engine(EngineConfig(modelPath = path, backend = backend, maxNumTokens = maxNum, cacheDir = cacheDir))
            e.initialize()
            engine = e
            val ms = SystemClock.elapsedRealtime() - t0
            Log.i(TAG, "load path=$path backend=$backendName maxNumTokens=$maxNum loadMs=$ms")
            main.post { result.success(mapOf("ok" to true, "loadMs" to ms, "backend" to backendName)) }
        } catch (t: Throwable) {
            Log.e(TAG, "load failed: $t", t)
            main.post { result.error("load_failed", t.message ?: t.toString(), null) }
        }
    }

    private fun unload() {
        for (c in checkpoints) closeQuietly(c.session)
        checkpoints.clear()
        engine?.let {
            try {
                it.close()
            } catch (t: Throwable) {
                Log.e(TAG, "engine close failed: $t")
            }
        }
        engine = null
    }

    private fun closeQuietly(s: Session) {
        try {
            if (s.isAlive) s.close()
        } catch (t: Throwable) {
            Log.e(TAG, "session close failed: $t")
        }
    }

    private fun stop() {
        stopRequested = true
        try {
            working?.cancelProcess()
        } catch (t: Throwable) {
            Log.e(TAG, "cancel failed: $t")
        }
    }

    // null: the model's own sampling. 0 (or less): greedy. Otherwise the temperature with Gemma's top-k and top-p.
    private fun samplerFor(temperature: Double?): SamplerConfig? = when {
        temperature == null -> null
        temperature <= 0.0 -> SamplerConfig(topK = 1, topP = 1.0, temperature = 0.0)
        else -> SamplerConfig(topK = TOP_K, topP = TOP_P, temperature = temperature)
    }

    private fun generate(id: Int, prompt: String, maxTokens: Int?, temperature: Double?) {
        val e = engine
        if (e == null) {
            emit(mapOf("id" to id, "error" to "No LiteRT model is loaded"))
            return
        }
        val t0 = SystemClock.elapsedRealtime()
        var session: Session? = null
        try {
            val samplerKey = temperature?.toString() ?: "default"
            // The longest checkpoint (same sampler) whose text starts this prompt.
            val best = checkpoints.filter { it.sampler == samplerKey && prompt.startsWith(it.text) }.maxByOrNull { it.text.length }
            val reused = best?.text?.length ?: 0
            session = best?.session?.clone() ?: e.createSession(SessionConfig(samplerConfig = samplerFor(temperature)))
            working = session
            val tPrefill = SystemClock.elapsedRealtime()
            if (stopRequested) throw CancellationException("stopped before prefill")
            if (prompt.length > reused) {
                session.runPrefill(listOf(InputData.Text(prompt.substring(reused))))
                // The checkpoint is taken before decoding, so it holds exactly this prompt.
                checkpoints.add(Checkpoint(prompt, samplerKey, session.clone()))
                while (checkpoints.size > MAX_CHECKPOINTS) closeQuietly(checkpoints.removeAt(0).session)
            }
            val prefillMs = SystemClock.elapsedRealtime() - tPrefill

            var chunks = 0
            var firstTokenMs = -1L
            var failure: Throwable? = null
            val finished = CountDownLatch(1)
            val s = session
            s.generateContentStream(emptyList(), object : ResponseCallback {
                override fun onNext(response: String) {
                    if (firstTokenMs < 0) firstTokenMs = SystemClock.elapsedRealtime() - t0
                    chunks++
                    emit(mapOf("id" to id, "chunk" to response))
                    if (maxTokens != null && maxTokens > 0 && chunks >= maxTokens) {
                        try {
                            s.cancelProcess()
                        } catch (t: Throwable) {
                            Log.e(TAG, "cancel failed: $t")
                        }
                    }
                }

                override fun onDone() {
                    finished.countDown()
                }

                override fun onError(throwable: Throwable) {
                    // A cancel (stop, or the token cap) is a normal end.
                    if (throwable !is CancellationException) failure = throwable
                    finished.countDown()
                }
            })
            finished.await()
            failure?.let { throw it }
            val totalMs = SystemClock.elapsedRealtime() - t0
            Log.i(
                TAG,
                "generate promptChars=${prompt.length} reusedChars=$reused prefillMs=$prefillMs firstTokenMs=$firstTokenMs totalMs=$totalMs chunks=$chunks",
            )
            emit(
                mapOf(
                    "id" to id, "done" to true, "prefillMs" to prefillMs, "firstTokenMs" to firstTokenMs,
                    "totalMs" to totalMs, "reusedChars" to reused, "chunks" to chunks,
                ),
            )
        } catch (t: CancellationException) {
            Log.i(TAG, "generate stopped")
            emit(
                mapOf(
                    "id" to id, "done" to true, "prefillMs" to 0, "firstTokenMs" to -1,
                    "totalMs" to SystemClock.elapsedRealtime() - t0, "reusedChars" to 0, "chunks" to 0,
                ),
            )
        } catch (t: Throwable) {
            Log.e(TAG, "generate failed: $t", t)
            emit(mapOf("id" to id, "error" to (t.message ?: t.toString())))
        } finally {
            working = null
            session?.let { closeQuietly(it) }
        }
    }
}

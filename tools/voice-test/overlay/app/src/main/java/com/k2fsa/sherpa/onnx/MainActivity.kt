// A cut-down copy of the sherpa-onnx Android TTS example (android/SherpaOnnxTts, Apache-2.0) set up for one model,
// Pocket TTS, with log lines that time it. It replaces the example's MainActivity.kt at build time
// (tools/voice-test/prepare.sh); the engine's own Tts.kt and WaveReader.kt are used unchanged.
//
// Changes from the example: the model is loaded and run on one background thread (the example loads on the main
// thread); the engine's callback only takes timestamps, and the audio is played after generating has ended, so the
// generating time is measured directly and is not mixed with playback; the speaker ID, speed, Save and Share
// controls are gone; thread count and flow steps are fields on screen and intent extras.
//
// Log lines, all under the tag PocketTiming, each with wall_ms (the clock time in milliseconds):
//   app_start    the activity was created
//   settings     the settings in effect after reading the fields and the intent extras
//   load_start   model loading begins (threads = the thread count the engine is created with)
//   load_end     model loading ended (load_ms)
//   ref_loaded   the reference clip was read from the APK (ref_samples, ref_rate)
//   gen_start    generating begins (run, threads, steps = flow steps, chars, ref, voice_cached)
//   first_chunk  the engine handed over its first piece of audio (since_start_ms)
//   chunk        every later piece (n, since_start_ms, samples, stream_samples so far)
//   gen_end      generating ended (gen_ms, first_chunk_ms, chunks, samples, sample_rate, audio_ms, rtf, threads, steps)
//   mem          the process's memory after a load or a run (pss_kb, native_heap_kb)
//   play_start, play_end   playback of the result
//   error        something failed (what, message)
//
// Intent extras, all optional: threads (int, default 2), steps (int, default 2), runs (int, generate this many
// times once the model is loaded, default 0), play (boolean, default true), seed (int, default -1 = random),
// ref (string, "donated" or "archive", default "donated"), text (string).
package com.k2fsa.sherpa.onnx

import android.content.Intent
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Debug
import android.os.SystemClock
import android.util.Log
import android.view.WindowManager
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import java.io.File
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicInteger

const val TAG = "PocketTiming"

private const val ENGINE_VERSION = "2.0.1"

// https://github.com/k2-fsa/sherpa-onnx/releases/tag/tts-models
private const val MODEL_DIR = "sherpa-onnx-pocket-tts-int8-2026-01-26"

private const val DEFAULT_THREADS = 2

// The engine's documentation runs its Pocket TTS example with 2 flow steps; its API default is 5.
private const val DEFAULT_STEPS = 2

// The reference clips in the APK (Pocket TTS clones the voice of a short clip). prepare.sh puts them there:
//   donated  a clip from the model makers' voices catalogue, voice-donations folder, licensed CC0
//   archive  the clip the engine's own Pocket TTS examples use, from the model archive's test_wavs
private const val DEFAULT_REF = "donated"
private val REF_ASSETS: Map<String, String> = mapOf(
    "donated" to "ref/donated.wav",
    "archive" to "ref/archive.wav",
)

// The sentence the engine's Pocket TTS examples use.
private const val SAMPLE_TEXT =
    "Today as always, men fall into two groups: slaves and free men. Whoever does not have " +
        "two-thirds of his day for himself, is a slave, whatever he may be, a statesman, a " +
        "businessman, an official, or a scholar."

class MainActivity : AppCompatActivity() {
    private lateinit var threadsField: EditText
    private lateinit var stepsField: EditText
    private lateinit var text: EditText
    private lateinit var status: TextView
    private lateinit var reload: Button
    private lateinit var generate: Button
    private lateinit var play: Button
    private lateinit var stop: Button

    // One thread does all the engine work (loading, generating, playback), one job at a time.
    private val worker: ExecutorService = Executors.newSingleThreadExecutor()
    private val pending = AtomicInteger(0)

    // Used only on the worker thread.
    private var tts: OfflineTts? = null
    private var track: AudioTrack? = null
    private var loadedThreads = 0
    private var refName = ""
    private var refSamples: FloatArray? = null
    private var refSampleRate = 0
    private var voiceCached = false
    private var runIndex = 0
    private var genStartNs = 0L
    private var firstChunkMs = -1L
    private var chunkCount = 0
    private var streamSamples = 0L

    // Set on the main thread, read on the worker thread.
    @Volatile
    private var playAfter = true

    @Volatile
    private var seed = -1

    @Volatile
    private var wantedRef = DEFAULT_REF

    @Volatile
    private var stopped = false

    // Used only on the main thread.
    private var mediaPlayer: MediaPlayer? = null
    private var hasWav = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        // The screen stays on, so a long run is not slowed by the phone going to sleep.
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        threadsField = findViewById(R.id.threads)
        stepsField = findViewById(R.id.steps)
        text = findViewById(R.id.text)
        status = findViewById(R.id.status)
        reload = findViewById(R.id.reload)
        generate = findViewById(R.id.generate)
        play = findViewById(R.id.play)
        stop = findViewById(R.id.stop)

        threadsField.setText(DEFAULT_THREADS.toString())
        stepsField.setText(DEFAULT_STEPS.toString())
        text.setText(SAMPLE_TEXT)

        reload.setOnClickListener { onClickReload() }
        generate.setOnClickListener { onClickGenerate() }
        play.setOnClickListener { onClickPlay() }
        stop.setOnClickListener { onClickStop() }

        Log.i(
            TAG,
            "app_start wall_ms=${System.currentTimeMillis()} engine=$ENGINE_VERSION model=$MODEL_DIR " +
                "sdk=${Build.VERSION.SDK_INT} cores=${Runtime.getRuntime().availableProcessors()}"
        )

        handleIntent(intent, true)
    }

    // A second "am start" while the app is open lands here (the activity is singleTop): new extras apply without
    // loading the model again, unless the thread count changed.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent, false)
    }

    override fun onDestroy() {
        stopped = true
        worker.execute {
            try {
                tts?.release()
            } catch (t: Throwable) {
                Log.e(TAG, "error wall_ms=${System.currentTimeMillis()} what=release message=${t.message}")
            }
            tts = null
            track?.release()
            track = null
        }
        worker.shutdown()
        mediaPlayer?.release()
        mediaPlayer = null
        super.onDestroy()
    }

    private fun handleIntent(intent: Intent?, launch: Boolean) {
        val extras = intent?.extras
        extraInt(extras, "threads")?.let { threadsField.setText(it.toString()) }
        extraInt(extras, "steps")?.let { stepsField.setText(it.toString()) }
        extraString(extras, "text")?.let { text.setText(it) }
        extraInt(extras, "seed")?.let { seed = it }
        extraBool(extras, "play")?.let { playAfter = it }
        val refExtra = extraString(extras, "ref")
        if (refExtra != null) {
            if (REF_ASSETS.containsKey(refExtra)) {
                wantedRef = refExtra
            } else {
                Log.e(
                    TAG,
                    "error wall_ms=${System.currentTimeMillis()} what=ref message=unknown reference clip $refExtra"
                )
            }
        }
        val runs = (extraInt(extras, "runs") ?: 0).coerceIn(0, 100)

        val threads = readThreads()
        val steps = readSteps()
        val textStr = text.text.toString().trim()
        val ref = wantedRef

        Log.i(
            TAG,
            "settings wall_ms=${System.currentTimeMillis()} launch=$launch threads=$threads steps=$steps " +
                "runs=$runs play=$playAfter seed=$seed ref=$ref chars=${textStr.length}"
        )

        stopped = false
        submit {
            ensureLoaded(threads, ref)
            var i = 0
            while (i < runs && !stopped) {
                runOnce(textStr, steps)
                i += 1
            }
        }
    }

    private fun onClickReload() {
        val threads = readThreads()
        val ref = wantedRef
        stopped = false
        submit {
            loadModel(threads)
            if (refSamples == null || refName != ref) {
                loadReference(ref)
            }
        }
    }

    private fun onClickGenerate() {
        val textStr = text.text.toString().trim()
        if (textStr.isEmpty()) {
            Toast.makeText(applicationContext, "Please input a non-empty text!", Toast.LENGTH_SHORT)
                .show()
            return
        }
        val threads = readThreads()
        val steps = readSteps()
        val ref = wantedRef
        stopped = false
        submit {
            ensureLoaded(threads, ref)
            runOnce(textStr, steps)
        }
    }

    private fun onClickPlay() {
        val file = File(filesDir, "generated.wav")
        if (!file.exists()) {
            return
        }
        mediaPlayer?.release()
        mediaPlayer = MediaPlayer.create(applicationContext, Uri.fromFile(file))
        mediaPlayer?.start()
    }

    // Stops generating at the engine's next piece of audio, and stops playback.
    private fun onClickStop() {
        stopped = true
        mediaPlayer?.release()
        mediaPlayer = null
    }

    private fun readThreads(): Int {
        val threads = (threadsField.text.toString().trim().toIntOrNull() ?: DEFAULT_THREADS).coerceIn(1, 16)
        threadsField.setText(threads.toString())
        return threads
    }

    private fun readSteps(): Int {
        val steps = (stepsField.text.toString().trim().toIntOrNull() ?: DEFAULT_STEPS).coerceIn(1, 100)
        stepsField.setText(steps.toString())
        return steps
    }

    // "adb shell am start" can pass a value as --ei, --es or --ez: any of them is read through its text.
    private fun extraString(extras: Bundle?, key: String): String? {
        val value = extras?.get(key) ?: return null
        return value.toString()
    }

    private fun extraInt(extras: Bundle?, key: String): Int? {
        return extraString(extras, key)?.trim()?.toIntOrNull()
    }

    private fun extraBool(extras: Bundle?, key: String): Boolean? {
        return when (extraString(extras, key)?.trim()?.lowercase(Locale.US)) {
            "true", "1", "yes" -> true
            "false", "0", "no" -> false
            else -> null
        }
    }

    // Main thread only. Queues a job for the worker thread; the buttons are off until the queue is empty.
    private fun submit(job: () -> Unit) {
        pending.incrementAndGet()
        refreshButtons()
        worker.execute {
            try {
                job()
            } catch (t: Throwable) {
                Log.e(
                    TAG,
                    "error wall_ms=${System.currentTimeMillis()} what=${t.javaClass.simpleName} message=${t.message}"
                )
                showStatus("Error: ${t.javaClass.simpleName}: ${t.message}")
            } finally {
                pending.decrementAndGet()
                runOnUiThread { refreshButtons() }
            }
        }
    }

    private fun refreshButtons() {
        val idle = pending.get() == 0
        reload.isEnabled = idle
        generate.isEnabled = idle
        play.isEnabled = idle && hasWav
    }

    private fun showStatus(message: String) {
        runOnUiThread { status.text = message }
    }

    private fun logMemory(at: String) {
        Log.i(
            TAG,
            "mem wall_ms=${System.currentTimeMillis()} at=$at pss_kb=${Debug.getPss()} " +
                "native_heap_kb=${Debug.getNativeHeapAllocatedSize() / 1024L}"
        )
    }

    // Everything below runs on the worker thread.

    private fun ensureLoaded(threads: Int, ref: String) {
        if (tts == null || loadedThreads != threads) {
            loadModel(threads)
        }
        if (refSamples == null || refName != ref) {
            loadReference(ref)
        }
    }

    // The thread count is fixed when the engine is created, so a new thread count means loading the model again.
    private fun loadModel(threads: Int) {
        // The old engine goes first, so two copies of the model are never in memory together.
        tts?.release()
        tts = null
        loadedThreads = 0
        voiceCached = false
        showStatus("Loading the model with $threads threads")

        val config = getOfflineTtsConfig(
            modelDir = MODEL_DIR,
            numThreads = threads,
            isPocket = true,
            lmFlow = "lm_flow.int8.onnx",
            lmMain = "lm_main.int8.onnx",
            pocketEncoder = "encoder.onnx",
            pocketDecoder = "decoder.int8.onnx",
            textConditioner = "text_conditioner.onnx",
            vocabJson = "vocab.json",
            tokenScoresJson = "token_scores.json",
        )

        Log.i(TAG, "load_start wall_ms=${System.currentTimeMillis()} threads=$threads model=$MODEL_DIR")
        val startNs = SystemClock.elapsedRealtimeNanos()
        val engine = OfflineTts(assetManager = application.assets, config = config)
        val endNs = SystemClock.elapsedRealtimeNanos()
        val endWall = System.currentTimeMillis()
        val loadMs = (endNs - startNs) / 1000000L
        val sampleRate = engine.sampleRate()
        Log.i(TAG, "load_end wall_ms=$endWall threads=$threads load_ms=$loadMs sample_rate=$sampleRate")

        tts = engine
        loadedThreads = threads
        if (track == null) {
            track = newTrack(sampleRate)
        }
        logMemory("load_end")
        showStatus("Model loaded in $loadMs ms with $threads threads")
    }

    private fun loadReference(name: String) {
        val path = REF_ASSETS[name] ?: throw IllegalArgumentException("unknown reference clip $name")
        val startNs = SystemClock.elapsedRealtimeNanos()
        val wave = WaveReader.readWave(assetManager = application.assets, filename = path)
        val readMs = (SystemClock.elapsedRealtimeNanos() - startNs) / 1000000L
        refSamples = wave.samples
        refSampleRate = wave.sampleRate
        refName = name
        voiceCached = false
        Log.i(
            TAG,
            "ref_loaded wall_ms=${System.currentTimeMillis()} ref=$name ref_samples=${wave.samples.size} " +
                "ref_rate=${wave.sampleRate} read_ms=$readMs"
        )
    }

    private fun newTrack(sampleRate: Int): AudioTrack {
        val bufLength = AudioTrack.getMinBufferSize(
            sampleRate,
            AudioFormat.CHANNEL_OUT_MONO,
            AudioFormat.ENCODING_PCM_FLOAT
        )
        val attr = AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .setUsage(AudioAttributes.USAGE_MEDIA)
            .build()
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
            .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
            .setSampleRate(sampleRate)
            .build()
        return AudioTrack(
            attr, format, bufLength, AudioTrack.MODE_STREAM,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )
    }

    // This function is called from C++, on the worker thread, each time the engine has a piece of audio ready.
    // It returns 1 to go on and 0 to stop.
    private fun onChunk(samples: FloatArray): Int {
        val sinceStartMs = (SystemClock.elapsedRealtimeNanos() - genStartNs) / 1000000L
        chunkCount += 1
        streamSamples += samples.size
        if (chunkCount == 1) {
            firstChunkMs = sinceStartMs
            Log.i(
                TAG,
                "first_chunk wall_ms=${System.currentTimeMillis()} run=$runIndex since_start_ms=$sinceStartMs " +
                    "samples=${samples.size}"
            )
        } else {
            Log.i(
                TAG,
                "chunk wall_ms=${System.currentTimeMillis()} run=$runIndex n=$chunkCount " +
                    "since_start_ms=$sinceStartMs samples=${samples.size} stream_samples=$streamSamples"
            )
        }
        return if (stopped) 0 else 1
    }

    private fun runOnce(textStr: String, steps: Int) {
        val engine = tts ?: throw IllegalStateException("the model is not loaded")
        val ref = refSamples ?: throw IllegalStateException("the reference clip is not loaded")
        if (textStr.isEmpty()) {
            throw IllegalArgumentException("the text is empty")
        }

        runIndex += 1
        chunkCount = 0
        streamSamples = 0L
        firstChunkMs = -1L
        val run = runIndex
        val threads = loadedThreads
        val cached = voiceCached
        val seedNow = seed
        val extra = HashMap<String, String>()
        if (seedNow >= 0) {
            extra["seed"] = seedNow.toString()
        }
        val genConfig = GenerationConfig(
            referenceAudio = ref,
            referenceSampleRate = refSampleRate,
            numSteps = steps,
            extra = extra,
        )
        showStatus("Generating: run $run, $threads threads, $steps flow steps")

        Log.i(
            TAG,
            "gen_start wall_ms=${System.currentTimeMillis()} run=$run threads=$threads steps=$steps " +
                "chars=${textStr.length} ref=$refName voice_cached=$cached seed=$seedNow"
        )
        genStartNs = SystemClock.elapsedRealtimeNanos()
        val audio = engine.generateWithConfigAndCallback(
            text = textStr,
            config = genConfig,
            callback = this::onChunk,
        )
        val endNs = SystemClock.elapsedRealtimeNanos()
        val endWall = System.currentTimeMillis()
        // The engine keeps the voice it worked out from the reference clip, so only the first run after a load
        // (or after a change of clip) pays for that.
        voiceCached = true

        val genMs = (endNs - genStartNs) / 1000000L
        val samples = audio.samples.size
        val sampleRate = audio.sampleRate
        val audioMs = if (sampleRate > 0) samples * 1000L / sampleRate else 0L
        val rtf = if (audioMs > 0L) {
            String.format(Locale.US, "%.3f", genMs.toDouble() / audioMs.toDouble())
        } else {
            "none"
        }
        Log.i(
            TAG,
            "gen_end wall_ms=$endWall run=$run gen_ms=$genMs first_chunk_ms=$firstChunkMs chunks=$chunkCount " +
                "samples=$samples sample_rate=$sampleRate audio_ms=$audioMs stream_samples=$streamSamples " +
                "rtf=$rtf threads=$threads steps=$steps"
        )
        logMemory("gen_end")

        if (samples == 0) {
            throw IllegalStateException("the engine returned no audio")
        }

        val saved = audio.save(File(filesDir, "generated.wav").absolutePath)
        runOnUiThread {
            hasWav = saved
            refreshButtons()
        }
        showStatus(
            "Run $run: $audioMs ms of speech generated in $genMs ms (real-time factor $rtf), first audio " +
                "after $firstChunkMs ms. $threads threads, $steps flow steps, reference clip: $refName."
        )

        if (playAfter && !stopped) {
            playSamples(audio.samples, sampleRate, run)
        }
    }

    // Plays the finished audio. Generating has ended by now, so playback takes nothing from the timed part.
    private fun playSamples(samples: FloatArray, sampleRate: Int, run: Int) {
        val player = track ?: return
        Log.i(TAG, "play_start wall_ms=${System.currentTimeMillis()} run=$run samples=${samples.size}")
        player.pause()
        player.flush()
        player.play()
        val step = maxOf(sampleRate / 5, 1)
        var pos = 0
        while (pos < samples.size && !stopped) {
            val n = minOf(step, samples.size - pos)
            val written = player.write(samples, pos, n, AudioTrack.WRITE_BLOCKING)
            if (written <= 0) {
                break
            }
            pos += written
        }
        if (stopped) {
            player.pause()
            player.flush()
        } else {
            player.stop()
        }
        Log.i(TAG, "play_end wall_ms=${System.currentTimeMillis()} run=$run written=$pos")
    }
}

package com.happylittlellc.cache

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.VibrationEffect
import android.util.Log
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The tick and the buzz of the CPR metronome (lib/firstaid/cpr_feedback.dart, channel co.cache/cpr).
 *
 * The tick is a short WAV the app makes (the 44-byte header, then 16-bit mono PCM) played from a static AudioTrack on the ALARM stream
 * with transient audio focus, so the ringer being on silent or vibrate does not mute it (alarm volume is its own). The buzz is a
 * one-shot vibration of the asked length.
 */
object CprBeat {
    private const val CHANNEL = "co.cache/cpr"
    private const val WAV_HEADER = 44
    private const val TAG = "CprBeat"

    private val attributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_ALARM)
        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
        .build()

    private var track: AudioTrack? = null
    private var focus: AudioFocusRequest? = null

    fun attach(context: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result -> handle(context, call, result) }
    }

    fun detach(context: Context, messenger: io.flutter.plugin.common.BinaryMessenger) {
        MethodChannel(messenger, CHANNEL).setMethodCallHandler(null)
        end(context)
    }

    private fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "begin" -> {
                val wav = call.argument<ByteArray>("wav")
                if (wav == null || wav.size <= WAV_HEADER) {
                    result.error("bad_sound", "No sound given", null)
                    return
                }
                begin(context, wav)
                result.success(null)
            }
            "tick" -> {
                tick()
                result.success(null)
            }
            "buzz" -> {
                buzz(context, (call.argument<Int>("ms") ?: 40).toLong())
                result.success(null)
            }
            "end" -> {
                end(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun begin(context: Context, wav: ByteArray) {
        end(context)
        val rate = (wav[24].toInt() and 0xff) or ((wav[25].toInt() and 0xff) shl 8) or ((wav[26].toInt() and 0xff) shl 16)
        val pcm = wav.copyOfRange(WAV_HEADER, wav.size)
        val t = AudioTrack.Builder()
            .setAudioAttributes(attributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(rate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build()
            )
            .setBufferSizeInBytes(pcm.size)
            .setTransferMode(AudioTrack.MODE_STATIC)
            .build()
        t.write(pcm, 0, pcm.size)
        track = t
        // Audio focus for the length of the session: music pauses (or lowers) and the ticks are heard.
        val audio = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
            .setAudioAttributes(attributes)
            .setOnAudioFocusChangeListener { }
            .build()
        val granted = audio.requestAudioFocus(request)
        focus = request
        // For the emulator and Pixel proofs: what the ticks will be played on.
        Log.i(TAG, "begin: alarm stream, ringer=${audio.ringerMode} (0 silent, 1 vibrate, 2 normal), alarm volume=${audio.getStreamVolume(AudioManager.STREAM_ALARM)}/${audio.getStreamMaxVolume(AudioManager.STREAM_ALARM)}, music volume=${audio.getStreamVolume(AudioManager.STREAM_MUSIC)}, focus granted=${granted == AudioManager.AUDIOFOCUS_REQUEST_GRANTED}, $rate Hz")
    }

    private fun tick() {
        val t = track ?: return
        try {
            t.stop()
            t.reloadStaticData()
            t.play()
        } catch (_: IllegalStateException) {
            // A track that cannot play again: the next tick tries once more.
        }
    }

    private fun buzz(context: Context, ms: Long) {
        val vibrator: Vibrator? = if (android.os.Build.VERSION.SDK_INT >= 31) {
            (context.getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            context.getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        vibrator?.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE))
        if (vibrator == null) Log.w(TAG, "no vibrator")
    }

    fun end(context: Context) {
        track?.let {
            try {
                it.stop()
            } catch (_: IllegalStateException) {
            }
            it.release()
        }
        track = null
        focus?.let { (context.getSystemService(Context.AUDIO_SERVICE) as AudioManager).abandonAudioFocusRequest(it) }
        focus = null
    }
}

package com.happylittlellc.cache.car

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Handler
import android.os.Looper

/**
 * Navigation audio focus for the spoken prompts while a car screen is attached: usage
 * `USAGE_ASSISTANCE_NAVIGATION_GUIDANCE`, gain `AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK`, as Android Auto asks of navigation apps (the
 * car's speakers then duck the music and play the prompt). The prompts are the phone's own, said by its text-to-speech (which is
 * already set to the navigation usage); this holds the focus while one plays and lets it go after.
 */
class CarAudio(context: Context) {
    private val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val main = Handler(Looper.getMainLooper())
    private val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_MAY_DUCK)
        .setAudioAttributes(ATTRIBUTES)
        .setOnAudioFocusChangeListener { change -> held = heldAfter(change) }
        .build()
    private val abandon = Runnable { release() }

    var held = false
        private set

    /** A prompt starts: take the focus (or keep it) for about as long as it takes to say [text]. */
    fun prompt(text: String) {
        if (!held) held = am.requestAudioFocus(request) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
        main.removeCallbacks(abandon)
        main.postDelayed(abandon, holdMs(text))
    }

    fun release() {
        main.removeCallbacks(abandon)
        if (held) am.abandonAudioFocusRequest(request)
        held = false
    }

    companion object {
        val ATTRIBUTES: AudioAttributes = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_ASSISTANCE_NAVIGATION_GUIDANCE)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()

        /**
         * Whether the focus is still held after [change]. Only a gain keeps it: after any loss (another app taking the audio
         * for good, for a while, or letting us duck) the next prompt asks for it again. Before, a loss for a while left it
         * counted as held, and the prompts after it did not ask until the hold ran out.
         */
        fun heldAfter(change: Int): Boolean = change == AudioManager.AUDIOFOCUS_GAIN

        /** About how long the phone takes to say [text] at the guidance rate, with a margin; at most 20 seconds. */
        fun holdMs(text: String): Long = (1500L + 80L * text.length).coerceAtMost(20_000L)
    }
}

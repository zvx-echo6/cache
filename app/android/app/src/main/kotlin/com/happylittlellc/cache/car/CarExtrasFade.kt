package com.happylittlellc.cache.car

/**
 * When the car's two extras (the route mini map and the climb) are drawn, as an opacity over time. Pure sums on a clock that
 * is handed in: no View, no timer.
 *
 * The extras are wanted or not ([want]). A change is not shown at once: after one pause ([pauseMs]) the extras fade, both
 * together, over [fadeMs]. If what is wanted changes back inside the pause, nothing on the car changes at all. A change that
 * comes during a fade waits its own pause from then, and fades from wherever the opacity is. [snap] sets the state with no
 * pause and no fade: the first frame of a drive, where the extras are either there with the car's own cards or not there.
 */
class CarExtrasFade(private val pauseMs: Long = PAUSE_MS, private val fadeMs: Long = FADE_MS) {
    /** What the opacity is at, or fading to. */
    private var shown = false

    /** What was last asked for. */
    private var wanted = false

    /** When the fade to [wanted] begins ([NONE]: nothing is waiting). */
    private var startAt = NONE

    /** When the fade that is running began ([NONE]: none is), and the opacity it began at. */
    private var fadeAt = NONE
    private var fadeFrom = 0f

    /** The extras are there, or are not, from this moment: no pause, no fade. */
    fun snap(on: Boolean) {
        shown = on
        wanted = on
        startAt = NONE
        fadeAt = NONE
    }

    /** The extras are wanted, or not, as of [now]. With [pause] false the fade begins at once (the car's free room changed:
     * that has already waited its own settle time). */
    fun want(on: Boolean, now: Long, pause: Boolean = true) {
        advance(now)
        if (on == wanted) return
        wanted = on
        startAt = if (wanted == shown) NONE else now + if (pause) pauseMs else 0L
    }

    /** What is wanted now (what the opacity will come to). */
    val heading: Boolean get() = wanted

    /** The opacity at [now]: 0 not drawn, 1 fully drawn. */
    fun alpha(now: Long): Float {
        advance(now)
        return alphaAt(now)
    }

    /** How long from [now] until the opacity next changes: 0 while a fade runs, the rest of the pause while one waits, null
     * while nothing is going to change (nothing needs to be drawn again). */
    fun nextIn(now: Long): Long? {
        advance(now)
        return when {
            fadeAt != NONE -> 0L
            startAt != NONE -> startAt - now
            else -> null
        }
    }

    private fun advance(now: Long) {
        if (startAt != NONE && now >= startAt) {
            fadeFrom = alphaAt(startAt)
            fadeAt = startAt
            shown = wanted
            startAt = NONE
        }
        if (fadeAt != NONE && now >= fadeAt + fadeMs) fadeAt = NONE
    }

    private fun alphaAt(t: Long): Float {
        val target = if (shown) 1f else 0f
        if (fadeAt == NONE) return target
        val f = if (fadeMs <= 0L) 1f else ((t - fadeAt).toFloat() / fadeMs).coerceIn(0f, 1f)
        return fadeFrom + (target - fadeFrom) * f
    }

    companion object {
        /** The owner's numbers (2026-11-12): the pause before a fade starts, in either direction, and how long the fade takes. */
        const val PAUSE_MS = 2000L
        const val FADE_MS = 500L

        private const val NONE = Long.MIN_VALUE
    }
}

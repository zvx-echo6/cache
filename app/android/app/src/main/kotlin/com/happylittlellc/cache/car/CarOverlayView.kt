package com.happylittlellc.cache.car

import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View

/**
 * The View that lays Cache's pieces (the route mini map and the climb) over the car map (see CarMapRenderer's header). It paints
 * [CarOverlayPainter] and does nothing else: no touch, no animation. New figures are shown in steps, at most once every
 * [MIN_STEP_MS], so the pieces never flicker or tween while the car moves. The route overview screen hides them, and they
 * are there only while the trip is guiding: when it stops they go at once, without waiting for the next step. A piece
 * also appears at once when its data first arrives; only the figures of a piece already showing wait for the step.
 */
class CarOverlayView(context: Context, private val density: Float) : View(context) {
    private val main = Handler(Looper.getMainLooper())
    private var width = 0
    private var height = 0
    private var visible: Rect? = null
    private var stable: Rect? = null
    private var dark = false
    private var overview = false
    private var shown: CarTrip = CarTrip.EMPTY
    private var pending: CarTrip? = null
    private var lastStepAt = 0L
    private var waiting = false
    private var waitingVisible: Rect? = null
    private var waitingStable: Rect? = null
    private val settle = Runnable {
        if (waiting) {
            waiting = false
            visible = waitingVisible
            stable = waitingStable
            invalidate()
        }
    }
    private val flush = Runnable {
        pending?.let { shown = it }
        pending = null
        lastStepAt = SystemClock.elapsedRealtime()
        invalidate()
    }

    init {
        isClickable = false
        isFocusable = false
        setWillNotDraw(false)
    }

    fun setSurfaceSize(w: Int, h: Int) {
        width = w
        height = h
    }

    /**
     * The host's two areas: [visible] is free of the host's parts, the camera places the vehicle in [stable]
     * (CarOverlayPainter.layout).
     *
     * Areas that keep the layout (one box or split) are taken at once, as are the first ones of a car session, up to the
     * first stable area. Areas that would CHANGE the layout are held back for [AREA_SETTLE_MS]: the host reports another
     * stable area for a moment when something of its own covers the guidance screen (a screen swapped and swapped back, a
     * message), and the pieces must not jump across the screen and back for that. If areas with the present layout come
     * back within that time nothing changes on the screen; if the new ones stay, the layout switches once.
     */
    fun setAreas(visible: Rect?, stable: Rect?) {
        val v = visible?.let { Rect(it) }
        val s = stable?.let { Rect(it) }
        main.removeCallbacks(settle)
        if (this.stable != null && modeOf(v, s) != modeOf(this.visible, this.stable)) {
            waitingVisible = v
            waitingStable = s
            waiting = true
            main.postDelayed(settle, AREA_SETTLE_MS)
            return
        }
        waiting = false
        this.visible = v
        this.stable = s
        invalidate()
    }

    private fun modeOf(visible: Rect?, stable: Rect?): CarOverlayMode =
        CarOverlayPainter.modeFor(stable ?: visible ?: Rect(0, 0, width, height), density)

    /** The route overview screen is up (CarMapRenderer.setOverview): the pieces are not drawn while it is. */
    fun setOverview(on: Boolean) {
        if (overview == on) return
        overview = on
        invalidate()
    }

    /** [now]: show it at once (the first trip, a day/night change); otherwise in the next step. A trip that is not guiding is
     * never held back for a step: the pieces of the route that ended go in this frame, and no waiting step can bring them back. */
    fun setTrip(t: CarTrip, dark: Boolean, now: Boolean) {
        val mode = this.dark != dark
        this.dark = dark
        if (!t.guiding) {
            main.removeCallbacks(flush)
            pending = null
            val was = shown.guiding
            shown = t
            if (was || mode) invalidate()
            return
        }
        val elapsed = SystemClock.elapsedRealtime() - lastStepAt
        // A piece whose data has just arrived is shown at once, not at the next step: after Start the first guiding trip
        // carries no route shape yet, and holding the one that does for a step left the pieces out for about three seconds.
        val appears = pieces(t) and pieces(shown).inv() != 0
        if (now || mode || appears || elapsed >= MIN_STEP_MS) {
            main.removeCallbacks(flush)
            pending = t
            flush.run()
        } else {
            pending = t
            main.removeCallbacks(flush)
            main.postDelayed(flush, MIN_STEP_MS - elapsed)
        }
    }

    fun stop() {
        main.removeCallbacks(flush)
        main.removeCallbacks(settle)
    }

    override fun onDraw(canvas: Canvas) = paint(canvas)

    /** What onDraw paints (its own function so a test can paint the View's present state onto a bitmap). */
    fun paint(canvas: Canvas) {
        val w = if (width > 0) width else getWidth()
        val h = if (height > 0) height else getHeight()
        CarOverlayPainter.draw(canvas, shown, w, h, visible, density, stable, overview)
    }

    companion object {
        /** The most often the pieces change. */
        const val MIN_STEP_MS = 3000L

        /** How long areas that would change the layout must hold before they do. On the car simulator the host showed
         * another screen for 0.2 to 0.5 s when it swapped the guidance screen out and back; one second is twice the
         * longest of those, and short enough that a change that is meant (the host's split view) follows promptly. */
        const val AREA_SETTLE_MS = 1000L

        const val PIECE_MINI_MAP = 1
        const val PIECE_CLIMB = 2

        /** Which pieces [t] has the data and the switches for (as CarOverlayPainter.draw decides), as bits. */
        fun pieces(t: CarTrip): Int {
            if (!t.guiding) return 0
            val mini = if (t.overlay.miniMap && t.overview != null) PIECE_MINI_MAP else 0
            val climb = if (t.overlay.climb && t.climb != null && !t.arrived) PIECE_CLIMB else 0
            return mini or climb
        }
    }
}

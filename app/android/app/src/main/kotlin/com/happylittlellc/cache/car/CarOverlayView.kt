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

    /** The host's two areas: [visible] is free of the host's parts, the camera places the vehicle in [stable] (CarOverlayPainter.layout). */
    fun setAreas(visible: Rect?, stable: Rect?) {
        this.visible = visible?.let { Rect(it) }
        this.stable = stable?.let { Rect(it) }
        invalidate()
    }

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

package com.happylittlellc.cache.car

import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.View

/**
 * The View that lays the climb card and the route mini map over the car map (see CarMapRenderer's header). It paints
 * [CarOverlayPainter] and does nothing else: no touch, no animation. New figures are shown in steps, at most once every
 * [MIN_STEP_MS], so the pieces never flicker or tween while the car moves.
 */
class CarOverlayView(context: Context, private val density: Float) : View(context) {
    private val main = Handler(Looper.getMainLooper())
    private var width = 0
    private var height = 0
    private var visible: Rect? = null
    private var stable: Rect? = null
    private var dark = false
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

    /** The host's two areas: the pieces go in [visible], the camera places the vehicle in [stable] (CarOverlayPainter.layout). */
    fun setAreas(visible: Rect?, stable: Rect?) {
        this.visible = visible?.let { Rect(it) }
        this.stable = stable?.let { Rect(it) }
        invalidate()
    }

    /** [now]: show it at once (the first trip, a day/night change); otherwise in the next step. */
    fun setTrip(t: CarTrip, dark: Boolean, now: Boolean) {
        val mode = this.dark != dark
        this.dark = dark
        val elapsed = SystemClock.elapsedRealtime() - lastStepAt
        if (now || mode || elapsed >= MIN_STEP_MS) {
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

    override fun onDraw(canvas: Canvas) {
        val w = if (width > 0) width else getWidth()
        val h = if (height > 0) height else getHeight()
        CarOverlayPainter.draw(canvas, shown, dark, w, h, visible, density, stable)
    }

    companion object {
        /** The most often the pieces change. */
        const val MIN_STEP_MS = 3000L
    }
}

package com.happylittlellc.cache.car

import android.content.Context
import android.graphics.Canvas
import android.graphics.Rect
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.View
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * The View that lays Cache's pieces (the route mini map and the climb) over the car map (see CarMapRenderer's header). It paints
 * [CarOverlayPainter] and does nothing else: no touch. New figures are shown in steps, at most once every
 * [MIN_STEP_MS], so the pieces never flicker or tween while the car moves. The route overview screen hides them, and they
 * are there only while the trip is guiding: when it stops they go at once, without waiting for the next step. A piece
 * also appears at once when its data first arrives; only the figures of a piece already showing wait for the step.
 *
 * Whether the pieces are on this car's screen at all is the screen's class, measured from the areas the car reports
 * ([CarOverlayPainter.extrasMeasure]): never on a small screen, always on a big one, and on an in-between one except while
 * the phone's drive screen is showing (the trip's `overlay.phoneDrive`). The one thing here that moves is that change: both
 * pieces fade together, after one pause ([CarExtrasFade]). On the first frame of a drive, and with the first areas of a car
 * session, the pieces are simply there or not. When the car's free room changes so that the pieces would move or go, they
 * fade out where they are, and fade in at the new place if the new room carries them.
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

    /** The screen's class for the areas in use, and whether the latest trip is guiding and says the phone's drive screen shows
     * (taken from every trip at once, not at the three-second step). */
    private var extras = CarExtrasClass.SMALL
    private var guidingNow = false
    private var phoneDrive = false
    private val fade = CarExtrasFade()
    private var said = false

    /** Areas that change the layout or take the pieces away, waiting for the pieces to have faded out where they are. */
    private var swapping = false
    private var swapVisible: Rect? = null
    private var swapStable: Rect? = null

    private val settle = Runnable {
        if (waiting) {
            waiting = false
            val now = SystemClock.elapsedRealtime()
            if (guidingNow && fade.alpha(now) > 0f) {
                // The pieces are showing: they fade out first, then the new areas are taken (step).
                swapping = true
                swapVisible = waitingVisible
                swapStable = waitingStable
                fade.want(false, now, pause = false)
                schedule()
            } else {
                take(waitingVisible, waitingStable)
                if (guidingNow) fade.want(extras.onCar(phoneDrive), now, pause = false)
                schedule()
            }
        }
    }

    /** Redraws while a fade runs (about thirty times a second, as the map is drawn) and once when a pause ends; nothing is
     * scheduled while nothing is going to change. */
    private val tick = Runnable {
        step(SystemClock.elapsedRealtime())
        invalidate()
        schedule()
    }

    private fun schedule() {
        main.removeCallbacks(tick)
        val wait = fade.nextIn(SystemClock.elapsedRealtime()) ?: return
        main.postDelayed(tick, max(wait, FRAME_MS))
    }

    /** Areas waiting for the pieces to be gone are taken once they are, and the pieces fade in there if that room has them. */
    private fun step(now: Long) {
        if (swapping && fade.alpha(now) <= 0f) {
            swapping = false
            take(swapVisible, swapStable)
            if (guidingNow) fade.want(extras.onCar(phoneDrive), now, pause = false)
        }
    }

    private fun take(v: Rect?, s: Rect?) {
        visible = v
        stable = s
        val m = CarOverlayPainter.extrasMeasure(surfaceW(), surfaceH(), v, density, s)
        if (m.cls != extras || (s != null && !said)) {
            said = s != null
            Log.i(TAG, "car extras: ${m.cls} (they ${if (m.fits) "fit" else "do not fit"}; ${m.extrasPx.roundToInt()} px of ${m.freePx.roundToInt()} px free map, ${(m.share * 100).roundToInt()} %)")
        }
        extras = m.cls
        invalidate()
    }

    private fun surfaceW() = if (width > 0) width else getWidth()

    private fun surfaceH() = if (height > 0) height else getHeight()

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
     * back within that time nothing changes on the screen; if the new ones stay, the layout switches once: the pieces fade
     * out where they are and fade in at their new place, or stay away where the new room is too small for them. Areas that
     * take the pieces away or bring them back (the screen's class to or from small) are held and faded the same way.
     */
    fun setAreas(visible: Rect?, stable: Rect?) {
        val v = visible?.let { Rect(it) }
        val s = stable?.let { Rect(it) }
        main.removeCallbacks(settle)
        val now = SystemClock.elapsedRealtime()
        // Areas that arrive while others wait for the pieces to fade out take their place.
        val wasSwapping = swapping
        swapping = false
        val first = this.stable == null
        if (!first && changesLayout(v, s)) {
            waitingVisible = v
            waitingStable = s
            waiting = true
            main.postDelayed(settle, AREA_SETTLE_MS)
            if (guidingNow) fade.want(extras.onCar(phoneDrive), now, pause = false)
            schedule()
            return
        }
        waiting = false
        take(v, s)
        if (guidingNow) {
            // The first areas of a car session: there or not, at once. Later ones that keep the layout: the class may have
            // gone between big and in-between, which is a change like the phone's and waits its pause.
            if (first) fade.snap(extras.onCar(phoneDrive)) else fade.want(extras.onCar(phoneDrive), now, pause = !wasSwapping)
        }
        schedule()
    }

    /** Whether new areas would move the pieces (another layout) or take them away or bring them back (small or not). */
    private fun changesLayout(v: Rect?, s: Rect?): Boolean {
        if (modeOf(v, s) != modeOf(this.visible, this.stable)) return true
        val small = CarOverlayPainter.extrasMeasure(surfaceW(), surfaceH(), v, density, s).cls == CarExtrasClass.SMALL
        return small != (extras == CarExtrasClass.SMALL)
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
        // The phone's drive screen, and the drive itself. A drive's first frame has the pieces or has not; after that a
        // change waits its pause and fades.
        val started = t.guiding && !guidingNow
        guidingNow = t.guiding
        phoneDrive = t.overlay.phoneDrive
        if (started) {
            fade.snap(extras.onCar(phoneDrive))
        } else if (t.guiding && !swapping) {
            fade.want(extras.onCar(phoneDrive), SystemClock.elapsedRealtime())
        }
        schedule()
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
        main.removeCallbacks(tick)
    }

    override fun onDraw(canvas: Canvas) = paint(canvas)

    /** What onDraw paints (its own function so a test can paint the View's present state onto a bitmap). */
    fun paint(canvas: Canvas) {
        val now = SystemClock.elapsedRealtime()
        step(now)
        val a = fade.alpha(now)
        if (a <= 0f) return
        if (a >= 1f) {
            CarOverlayPainter.draw(canvas, shown, surfaceW(), surfaceH(), visible, density, stable, overview)
            return
        }
        // Part of the way through a fade: both pieces together, as one picture at that opacity.
        val layer = canvas.saveLayerAlpha(null, (a * 255f).roundToInt())
        CarOverlayPainter.draw(canvas, shown, surfaceW(), surfaceH(), visible, density, stable, overview)
        canvas.restoreToCount(layer)
    }

    companion object {
        /** The most often the pieces change. */
        const val MIN_STEP_MS = 3000L

        /** How long areas that would change the layout must hold before they do. On the car simulator the host showed
         * another screen for 0.2 to 0.5 s when it swapped the guidance screen out and back; one second is twice the
         * longest of those, and short enough that a change that is meant (the host's split view) follows promptly. */
        const val AREA_SETTLE_MS = 1000L

        /** Between two redraws of a fade: thirty a second, as the car's map is drawn. */
        const val FRAME_MS = 33L

        private const val TAG = "CacheCarMap"

        const val PIECE_MINI_MAP = 1
        const val PIECE_CLIMB = 2

        /** Which pieces [t] has the data for (as CarOverlayPainter.draw decides), as bits. */
        fun pieces(t: CarTrip): Int {
            if (!t.guiding) return 0
            val mini = if (t.overview != null) PIECE_MINI_MAP else 0
            val climb = if (t.climb != null && !t.arrived) PIECE_CLIMB else 0
            return mini or climb
        }
    }
}

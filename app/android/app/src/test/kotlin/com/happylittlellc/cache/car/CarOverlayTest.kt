package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.os.Looper
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File
import kotlin.math.cos

/**
 * The climb card and route mini map: parsing of the trip's blocks, the painter's layout maths, and the renders of the approved
 * design (Light, Parchment, Dark and Tactical with both pieces on, Dark with both off) at 1280 x 560.
 *
 * SAMPLE DATA: the figures are the mockup's demo numbers (about 3,350 ft of climb, 9% in 2.3 mi, a route about a third
 * driven), not a real route. The map behind is a stand-in fill with a few road lines (MapLibre does not render in a JVM test),
 * so the main map's route and badge here are drawn with the same painter calls on a plain canvas: the overlay painter is the
 * real code, the MapLibre layers are not.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class CarOverlayTest {
    private val fixture: JSONObject by lazy {
        JSONObject(javaClass.classLoader!!.getResourceAsStream("car/overlay_palette.json")!!.bufferedReader().readText())
    }

    private fun colorsMap(theme: String): Map<String, Any?> {
        val o = fixture.getJSONObject(theme)
        return o.keys().asSequence().associateWith { o.getString(it) }
    }

    private fun palette(theme: String) = mapOf("day" to colorsMap(theme), "night" to colorsMap(theme))

    // ---- sample data (the mock's numbers) -------------------------------------------------------------------------------

    private fun sampleHeights(): List<Double> {
        // The mock's shape, y from 48 (low) to 5 (high), at x = 0, 30, 60, 90, 108, 124, 160, 196.
        val xs = doubleArrayOf(0.0, 30.0, 60.0, 90.0, 108.0, 124.0, 160.0, 196.0)
        val ys = doubleArrayOf(48.0, 46.0, 40.0, 32.0, 18.0, 10.0, 7.0, 5.0)
        return (0 until 56).map { i ->
            val x = 196.0 * i / 55
            var k = 1
            while (k < xs.size - 1 && xs[k] < x) k++
            val t = (x - xs[k - 1]) / (xs[k] - xs[k - 1])
            val y = ys[k - 1] + (ys[k] - ys[k - 1]) * t
            1200.0 + (48.0 - y) * 20.0
        }
    }

    private fun bezier(p0: DoubleArray, p1: DoubleArray, p2: DoubleArray, p3: DoubleArray, n: Int): List<DoubleArray> =
        (0..n).map { i ->
            val t = i.toDouble() / n
            val u = 1 - t
            doubleArrayOf(
                u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
            )
        }

    /** The mini map's route in the mock's picture coordinates, as (lat, lon) so the painter's own projection gives the mock's look. */
    private fun sampleOverview(): Map<String, Any?> {
        val a = bezier(doubleArrayOf(24.0, 122.0), doubleArrayOf(50.0, 110.0), doubleArrayOf(60.0, 90.0), doubleArrayOf(90.0, 84.0), 20)
        val b = bezier(doubleArrayOf(90.0, 84.0), doubleArrayOf(120.0, 78.0), doubleArrayOf(130.0, 60.0), doubleArrayOf(140.0, 46.0), 20)
        val c = bezier(doubleArrayOf(140.0, 46.0), doubleArrayOf(150.0, 32.0), doubleArrayOf(170.0, 22.0), doubleArrayOf(196.0, 18.0), 20)
        val px = a + b.drop(1) + c.drop(1)
        val lat0 = 43.0
        fun lat(y: Double) = lat0 - y * 0.0005
        fun lon(x: Double) = -116.0 + x * 0.0005 / cos(Math.toRadians(lat0))
        return mapOf(
            "points" to px.map { listOf(lat(it[1]), lon(it[0])) },
            "drivenFraction" to 0.33,
            "steep" to mapOf("lat" to lat(46.0), "lon" to lon(140.0), "gradePct" to 9.0),
            "destination" to mapOf("lat" to lat(18.0), "lon" to lon(196.0)),
        )
    }

    private fun sampleClimb(): Map<String, Any?> = mapOf(
        "climbAheadM" to 3350.0 / 3.28084,
        "gradePct" to 9.0,
        "steepestInM" to 2.3 * 1609.344,
        "heightsM" to sampleHeights(),
        "steepFrom" to 25,
        "steepTo" to 35,
        "windowM" to 8000.0,
    )

    private fun trip(theme: String, climb: Boolean = true, mini: Boolean = true, imperial: Boolean = true): CarTrip = CarTrip.from(
        mapOf(
            "phase" to "guiding", "available" to true, "units" to if (imperial) "imperial" else "metric",
            "overlay" to mapOf("climb" to climb, "miniMap" to mini),
            "climb" to sampleClimb(), "overview" to sampleOverview(), "palette" to palette(theme),
        ),
    )

    // ---- parsing ----------------------------------------------------------------------------------------------------

    @Test
    fun theTripBlocksAreParsed() {
        val t = trip("dark")
        assertTrue(t.overlay.climb)
        assertTrue(t.overlay.miniMap)
        val c = t.climb!!
        assertEquals(56, c.heightsM.size)
        assertEquals(9.0, c.gradePct!!, 0.0)
        assertEquals(25, c.steepFrom)
        assertEquals(35, c.steepTo)
        val o = t.overview!!
        assertEquals(0.33, o.drivenFraction, 0.0)
        assertEquals(61, o.points.size)
        assertNotNull(o.steepLat)
        assertEquals(9.0, o.steepGradePct!!, 0.0)
        val p = t.palette!!
        assertEquals("dark", p.night.theme)
        assertEquals(0xFF6BB4DE.toInt(), p.night.route)
        assertEquals(0xFFF4F6F8.toInt(), p.night.badge)
    }

    @Test
    fun noBlocksMeansNoPiecesAndDefaultsAreOn() {
        val t = CarTrip.from(mapOf("phase" to "guiding"))
        assertNull(t.climb)
        assertNull(t.overview)
        assertNull(t.palette)
        assertTrue(t.overlay.climb && t.overlay.miniMap)
        // A climb block with too few heights, a bad palette: dropped, not a crash.
        val odd = CarTrip.from(mapOf("phase" to "guiding", "climb" to mapOf("heightsM" to listOf(1.0)), "palette" to mapOf("day" to mapOf("route" to "nope"))))
        assertNull(odd.climb)
        assertNull(odd.palette)
    }

    @Test
    fun theHostCardColorComesFromThePaletteAsLightAndDarkVariants() {
        val t = CarTrip.from(mapOf("phase" to "guiding", "palette" to mapOf("day" to colorsMap("light"), "night" to colorsMap("tactical"))))
        val c = CarModels.hostBackground(t)!!
        assertEquals(androidx.car.app.model.CarColor.TYPE_CUSTOM, c.type)
        assertEquals(0xFFFFFDF8.toInt(), c.color)
        assertEquals(0xFF3A0B07.toInt(), c.colorDark)
        assertNull(CarModels.hostBackground(CarTrip.from(mapOf("phase" to "guiding"))))
    }

    @Test
    fun switchesAreReadFromTheTrip() {
        val t = trip("dark", climb = false, mini = true)
        assertFalse(t.overlay.climb)
        assertTrue(t.overlay.miniMap)
    }

    // ---- layout maths -----------------------------------------------------------------------------------------------

    private val visible = Rect(88, 0, 1280, 560)

    @Test
    fun bothPiecesSitInsideTheVisibleAreaBottomLeftAndBottomRight() {
        val l = CarOverlayPainter.layout(1280, 560, visible, 1f, showClimb = true, showMini = true)
        val c = l.climb!!
        val m = l.mini!!
        assertEquals(88f + 16f, c.left, 0.01f)
        assertEquals(380f, c.width(), 0.01f)
        // The card's top is where the mock's 97 high card had it; the larger text made it 121 high, downwards.
        assertEquals(560f - 16f - 58f - 97f, c.top, 0.01f)
        assertEquals(121f, c.height(), 0.01f)
        assertEquals(220f, m.width(), 0.01f)
        assertEquals(140f, m.height(), 0.01f)
        assertEquals(1280f - 16f - 84f, m.right, 0.01f)
        assertEquals(560f - 16f, m.bottom, 0.01f)
        for (r in listOf(c, m)) {
            assertTrue(r.left >= visible.left && r.right <= visible.right && r.top >= visible.top && r.bottom <= visible.bottom)
        }
        assertFalse(RectF.intersects(c, m))
    }

    @Test
    fun aSmallerVisibleAreaMovesThePiecesIn() {
        val v = Rect(300, 80, 1100, 500)
        val l = CarOverlayPainter.layout(1280, 560, v, 1f, showClimb = true, showMini = true)
        for (r in listOfNotNull(l.climb, l.mini)) {
            assertTrue(r.left >= v.left && r.right <= v.right && r.top >= v.top && r.bottom <= v.bottom)
        }
        assertNotNull(l.mini)
        assertFalse(l.climb != null && RectF.intersects(l.climb, l.mini!!))
    }

    @Test
    fun theDensityScalesEverything() {
        val one = CarOverlayPainter.layout(2560, 1120, Rect(176, 0, 2560, 1120), 2f, showClimb = true, showMini = true)
        assertEquals(760f, one.climb!!.width(), 0.01f)
        assertEquals(440f, one.mini!!.width(), 0.01f)
    }

    @Test
    fun aSwitchedOffPieceHasNoRectAndAnAreaTooSmallHasNone() {
        assertNull(CarOverlayPainter.layout(1280, 560, visible, 1f, showClimb = false, showMini = true).climb)
        assertNull(CarOverlayPainter.layout(1280, 560, visible, 1f, showClimb = true, showMini = false).mini)
        val tiny = CarOverlayPainter.layout(1280, 560, Rect(0, 0, 200, 100), 1f, showClimb = true, showMini = true)
        assertNull(tiny.climb)
        assertNull(tiny.mini)
    }

    // ---- the vehicle stays clear (areas as measured on the car simulator, density 1) ------------------------------------

    /** The marker as the map draws it (the arrow pointing up the screen: 30 wide, its tip 19 above the position and its tails
     * 15 below) and the road ahead of it (the route's 12 px casing, up to the top of the area): worked out here from the
     * camera's rule, not from the painter's keep-clear zone. */
    private fun assertVehicleClear(l: CarOverlayPainter.Layout, stable: Rect) {
        val vx = (stable.left + stable.right) / 2f
        val vy = stable.top + stable.height() * 0.675f
        val marker = RectF(vx - 15f, vy - 19f, vx + 15f, vy + 15f)
        val ahead = RectF(vx - 6f, stable.top.toFloat(), vx + 6f, vy)
        for (r in listOfNotNull(l.climb, l.mini)) {
            assertFalse("$r is over the vehicle $marker", RectF.intersects(r, marker))
            assertFalse("$r is over the road ahead $ahead", RectF.intersects(r, ahead))
        }
    }

    private fun assertRect(left: Float, top: Float, right: Float, bottom: Float, r: RectF?) {
        assertNotNull(r)
        assertEquals(left, r!!.left, 0.51f)
        assertEquals(top, r.top, 0.51f)
        assertEquals(right, r.right, 0.51f)
        assertEquals(bottom, r.bottom, 0.51f)
    }

    private val mainStable = Rect(504, 91, 1181, 697)

    @Test
    fun theCameraPutsTheVehicleWhereTheLayoutExpectsIt() {
        // 1280 x 720: the marker was measured at (843, 500).
        val v = CarOverlayPainter.vehiclePoint(mainStable)
        assertEquals(843f, v.x, 1f)
        assertEquals(500f, v.y, 1f)
        // The same share the camera pads the top with: the point is the middle of what is left under it.
        val inset = CarOverlayPainter.guidanceTopInset(mainStable)
        assertEquals(0.35 * 606, inset, 1e-6)
        assertEquals((91 + inset + 697) / 2.0, v.y.toDouble(), 0.01)
        val keep = CarOverlayPainter.keepClear(mainStable, 1f)
        assertTrue(keep.contains(v.x, v.y) && keep.top == 91f && keep.bottom >= v.y + 15f && keep.left <= v.x - 15f && keep.right >= v.x + 15f)
    }

    @Test
    fun theKeepClearZoneIsTheArrowsSizeAndNoSmallerThanTheDot() {
        // The arrow, pointing up the screen as it does while guiding: half its 30 px width to each side of the position, its
        // tails 15 px below it. The dot (drawn while no heading is known) is 14 px each way, so the zone covers it too.
        assertEquals(15f, CarOverlayPainter.MARKER_SIDE, 0f)
        assertEquals(15f, CarOverlayPainter.MARKER_BELOW, 0f)
        val dot = CarOverlayPainter.POS_RADIUS + CarOverlayPainter.POS_RING
        assertTrue(CarOverlayPainter.MARKER_SIDE >= dot && CarOverlayPainter.MARKER_BELOW >= dot)
        val v = CarOverlayPainter.vehiclePoint(mainStable)
        val keep = CarOverlayPainter.keepClear(mainStable, 1f)
        // 16 px of free map beside the arrow on each side; under its tails a piece may begin.
        assertEquals(v.x - 31f, keep.left, 0.01f)
        assertEquals(v.x + 31f, keep.right, 0.01f)
        assertEquals(v.y + 15f, keep.bottom, 0.01f)
        // Twice the density: twice the zone.
        val keep2 = CarOverlayPainter.keepClear(mainStable, 2f)
        assertEquals(v.x - 62f, keep2.left, 0.01f)
        assertEquals(v.y + 30f, keep2.bottom, 0.01f)
    }

    @Test
    fun at1280x720TheApprovedLayoutDoesNotMove() {
        // The host's buttons showing: the visible area is the stable area.
        val shown = CarOverlayPainter.layout(1280, 720, mainStable, 1f, showClimb = true, showMini = true, stable = mainStable)
        // The climb card's top left corner and its right end are the approved ones; its bottom was 623 before its text grew.
        assertRect(520f, 526f, 845f, 647f, shown.climb)
        assertRect(861f, 541f, 1081f, 681f, shown.mini)
        assertVehicleClear(shown, mainStable)
        // The buttons hidden: the visible area reaches 77 px further right, the vehicle stays.
        val hidden = CarOverlayPainter.layout(1280, 720, Rect(504, 91, 1258, 697), 1f, showClimb = true, showMini = true, stable = mainStable)
        assertRect(520f, 526f, 900f, 647f, hidden.climb)
        assertRect(938f, 541f, 1158f, 681f, hidden.mini)
        assertVehicleClear(hidden, mainStable)
    }

    @Test
    fun at800x480NeitherPieceIsDrawnBecauseBothWouldCoverTheVehicle() {
        val stable = Rect(344, 80, 711, 387)
        val l = CarOverlayPainter.layout(800, 480, stable, 1f, showClimb = true, showMini = true, stable = stable)
        assertNull(l.mini)
        assertNull(l.climb)
        // The climb card alone has no room either.
        assertNull(CarOverlayPainter.layout(800, 480, stable, 1f, showClimb = true, showMini = false, stable = stable).climb)
        // The buttons hidden (more room on the right): still on the vehicle, still not drawn.
        val hidden = CarOverlayPainter.layout(800, 480, Rect(344, 80, 788, 387), 1f, showClimb = true, showMini = true, stable = stable)
        assertNull(hidden.mini)
        assertVehicleClear(hidden, stable)
    }

    @Test
    fun onTheWideScreenTheClimbCardEndsShortOfTheVehicleAndTheMiniMapGoesFirst() {
        // 1280 x 500: the vehicle is level with the cards.
        val stable = Rect(504, 91, 1181, 477)
        val keep = CarOverlayPainter.keepClear(stable, 1f)
        val shown = CarOverlayPainter.layout(1280, 500, stable, 1f, showClimb = true, showMini = true, stable = stable)
        assertNull(shown.mini)
        val c = shown.climb!!
        assertEquals(520f, c.left, 0.51f)
        assertEquals(keep.left, c.right, 0.01f)
        // Its top is where the 97 high card had it, and the taller card still ends inside the area.
        assertEquals(306f, c.top, 0.51f)
        assertEquals(427f, c.bottom, 0.51f)
        assertTrue(c.bottom <= stable.bottom - 16f)
        // It ends 16 px short of the arrow's left edge: at 811.5 (812.5 when the marker was the 14 px dot).
        assertEquals(811.5f, c.right, 0.01f)
        assertTrue(c.right < 843f - 15f)
        assertVehicleClear(shown, stable)
        // The buttons hidden: the mini map has room right of the vehicle, the climb card still ends short of it.
        val hidden = CarOverlayPainter.layout(1280, 500, Rect(504, 91, 1258, 477), 1f, showClimb = true, showMini = true, stable = stable)
        assertRect(938f, 321f, 1158f, 461f, hidden.mini)
        assertEquals(keep.left, hidden.climb!!.right, 0.01f)
        assertVehicleClear(hidden, stable)
    }

    @Test
    fun inTheNarrowPaneAndInSplitViewOnlyTheMiniMapIsDrawnBelowTheVehicle() {
        // The 410 px pane.
        val narrow = Rect(12, 84, 398, 613)
        val n = CarOverlayPainter.layout(410, 700, narrow, 1f, showClimb = true, showMini = true, stable = narrow)
        assertNull(n.climb)
        assertRect(78f, 457f, 298f, 597f, n.mini)
        assertTrue(n.mini!!.top >= CarOverlayPainter.vehiclePoint(narrow).y + 15f)
        assertVehicleClear(n, narrow)
        // Split view, 770 px.
        val split = Rect(344, 81, 683, 687)
        val s = CarOverlayPainter.layout(770, 700, split, 1f, showClimb = true, showMini = true, stable = split)
        assertNull(s.climb)
        assertRect(363f, 531f, 583f, 671f, s.mini)
        assertVehicleClear(s, split)
    }

    @Test
    fun aPieceThatWouldCoverTheVehicleIsNeverReturnedWhateverTheAreas() {
        for (w in 300..1300 step 50) for (h in 250..750 step 50) for (inset in listOf(0, 40, 120)) {
            val stable = Rect(inset, inset / 2, w - inset / 3, h - inset / 4)
            for (extra in listOf(0, 77)) {
                val visible = Rect(stable.left, stable.top, minOf(w, stable.right + extra), stable.bottom)
                assertVehicleClear(CarOverlayPainter.layout(w, h, visible, 1f, showClimb = true, showMini = true, stable = stable), stable)
                assertVehicleClear(CarOverlayPainter.layout(w, h, visible, 1f, showClimb = true, showMini = false, stable = stable), stable)
            }
        }
    }

    // ---- when the pieces are drawn at all -------------------------------------------------------------------------------

    /** Whether the View paints the climb card and the mini map right now (1280 x 560, the mock's visible area). */
    private fun painted(v: CarOverlayView): Pair<Boolean, Boolean> {
        val bmp = Bitmap.createBitmap(1280, 560, Bitmap.Config.ARGB_8888)
        v.paint(Canvas(bmp))
        val l = CarOverlayPainter.layout(1280, 560, visible, 1f, showClimb = true, showMini = true)
        return Pair(
            bmp.getPixel((l.climb!!.left + 100).toInt(), (l.climb!!.top + 3).toInt()) != 0,
            bmp.getPixel((l.mini!!.left + 100).toInt(), (l.mini!!.top + 3).toInt()) != 0,
        )
    }

    private fun overlayView() = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
        setSurfaceSize(1280, 560)
        setAreas(visible, null)
    }

    @Test
    fun neitherPieceIsDrawnWhileTheRouteOverviewIsShown() {
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        v.setOverview(true)
        assertEquals(Pair(false, false), painted(v))
        // Figures that arrive while the overview is up do not bring them back.
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(false, false), painted(v))
        v.setOverview(false)
        assertEquals(Pair(true, true), painted(v))
        // The painter itself: the overview flag alone stops both pieces.
        val bmp = Bitmap.createBitmap(1280, 560, Bitmap.Config.ARGB_8888)
        CarOverlayPainter.draw(Canvas(bmp), trip("dark"), dark = true, width = 1280, height = 560, visible = visible, density = 1f, overview = true)
        val px = IntArray(1280 * 560)
        bmp.getPixels(px, 0, 1280, 0, 0, 1280, 560)
        assertTrue(px.all { it == 0 })
    }

    @Test
    fun thePiecesGoInTheSameFrameGuidanceStops() {
        val ended = CarTrip.from(mapOf("phase" to "browsing", "palette" to palette("dark")))
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        // Guidance ends within the step time of the last figures: not held back for the next step.
        v.setTrip(ended, dark = true, now = false)
        assertEquals(Pair(false, false), painted(v))

        // New figures were waiting for their step when guidance ended: the step does not bring the pieces back.
        val w = overlayView()
        w.setTrip(trip("dark"), dark = true, now = true)
        w.setTrip(trip("dark"), dark = true, now = false)
        w.setTrip(ended, dark = true, now = false)
        assertEquals(Pair(false, false), painted(w))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(2 * CarOverlayView.MIN_STEP_MS))
        assertEquals(Pair(false, false), painted(w))

        // Guiding with the route preview's phase or any other: nothing either (only the guiding phase draws).
        val x = overlayView()
        x.setTrip(CarTrip.from(mapOf("phase" to "previewing", "climb" to sampleClimb(), "overview" to sampleOverview(), "palette" to palette("dark"))), dark = true, now = true)
        assertEquals(Pair(false, false), painted(x))
    }

    @Test
    fun theClimbCardIsNotDrawnOnArrival() {
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        // Arrived, and the trip still carries a climb: the card goes, the mini map stays.
        v.setTrip(trip("dark").copy(arrived = true), dark = true, now = true)
        assertEquals(Pair(false, true), painted(v))
    }

    // ---- the climb card's text: size and contrast -----------------------------------------------------------------------

    @Test
    fun noTextOnTheClimbCardIsSmallerThanTheHostsSmallestLine() {
        // The host's smallest line on the guidance screen is 24 px at density 1 (measured on the car simulator).
        assertEquals(24f, CarOverlayPainter.HOST_MIN_TEXT, 0f)
        for (size in listOf(CarOverlayPainter.CLIMB_LABEL_SIZE, CarOverlayPainter.CLIMB_FIGURE_SIZE, CarOverlayPainter.CLIMB_GRADE_SIZE)) {
            assertTrue("$size", size >= CarOverlayPainter.HOST_MIN_TEXT)
        }
        // The figure is the main thing: 34, well above the two 24 lines (the mock had it at twice its label).
        assertEquals(34f, CarOverlayPainter.CLIMB_FIGURE_SIZE, 0f)
        assertTrue(CarOverlayPainter.CLIMB_FIGURE_SIZE >= 1.4f * CarOverlayPainter.CLIMB_LABEL_SIZE)
        assertTrue(CarOverlayPainter.CLIMB_FIGURE_SIZE >= 1.4f * CarOverlayPainter.CLIMB_GRADE_SIZE)
        // The card holds the three lines: it is 121 high, as wide as before, and the figure clears the label above it.
        assertEquals(121f, CarOverlayPainter.CLIMB_H, 0f)
        assertEquals(380f, CarOverlayPainter.CLIMB_W, 0f)
        assertTrue(CarOverlayPainter.CLIMB_FIGURE_DROP >= CarOverlayPainter.CLIMB_FIGURE_SIZE)
        assertTrue(CarOverlayPainter.CLIMB_GRADE_DROP >= CarOverlayPainter.CLIMB_GRADE_SIZE)
        val lines = CarOverlayPainter.CLIMB_LABEL_SIZE + CarOverlayPainter.CLIMB_FIGURE_DROP + CarOverlayPainter.CLIMB_GRADE_DROP
        assertTrue(CarOverlayPainter.CLIMB_PAD_Y * 2 + lines <= CarOverlayPainter.CLIMB_H)
    }

    private fun luminance(c: Int): Double {
        fun ch(v: Int): Double {
            val s = v / 255.0
            return if (s <= 0.03928) s / 12.92 else Math.pow((s + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch((c shr 16) and 0xFF) + 0.7152 * ch((c shr 8) and 0xFF) + 0.0722 * ch(c and 0xFF)
    }

    private fun contrast(a: Int, b: Int): Double {
        val x = luminance(a)
        val y = luminance(b)
        return (maxOf(x, y) + 0.05) / (minOf(x, y) + 0.05)
    }

    @Test
    fun textOnTheClimbCardReadsAtFourAndAHalfToOneInAllFourThemes() {
        for (theme in listOf("light", "parchment", "dark", "tactical")) {
            val p = trip(theme).palette!!.night
            assertTrue("$theme figures ${contrast(p.cardText, p.card)}", contrast(p.cardText, p.card) >= 4.5)
            assertTrue("$theme label ${contrast(p.cardSecondary, p.card)}", contrast(p.cardSecondary, p.card) >= 4.5)
        }
        // Tactical is not left near the limit: both reds are at 6:1 or better on its card.
        val t = trip("tactical").palette!!.night
        assertTrue(contrast(t.cardSecondary, t.card) >= 6.0 && contrast(t.cardText, t.card) >= 6.0)
    }

    // ---- the climb card's shape is to scale ------------------------------------------------------------------------------

    @Test
    fun theShapesFullHeightStandsForAtLeastAHundredMetersOfRise() {
        assertEquals(100.0, CarOverlayPainter.SHAPE_MIN_RISE_M, 0.0)
        // The shape's line runs between y 5 (high) and y 48 (low); the middle is 26.5.
        fun y(h: Double, lo: Double, hi: Double) = CarOverlayPainter.shapeY(h, lo, hi, 5f, 48f)
        // A flat road: a level line at the middle, where it was.
        assertEquals(26.5f, y(1200.0, 1200.0, 1200.0), 0.001f)
        // A 2 m bump: under half a pixel either side of the middle, not the whole box.
        assertEquals(26.5f - 0.43f, y(1002.0, 1000.0, 1002.0), 0.01f)
        assertEquals(26.5f + 0.43f, y(1000.0, 1000.0, 1002.0), 0.01f)
        // 50 m of rise: half the height.
        assertEquals(26.5f - 10.75f, y(1050.0, 1000.0, 1050.0), 0.01f)
        assertEquals(26.5f + 10.75f, y(1000.0, 1000.0, 1050.0), 0.01f)
        // 100 m and more: the whole height, scaled to the real range as before.
        assertEquals(5f, y(1100.0, 1000.0, 1100.0), 0.01f)
        assertEquals(48f, y(1000.0, 1000.0, 1100.0), 0.01f)
        assertEquals(5f, y(1600.0, 1000.0, 1600.0), 0.01f)
        assertEquals(48f, y(1000.0, 1000.0, 1600.0), 0.01f)
        assertEquals(26.5f, y(1300.0, 1000.0, 1600.0), 0.01f)
    }

    /** The rows of the shape's line (the route color at full strength), right of the start dot, for [heights] in a 196 x 52 box. */
    private fun shapeLineRows(heights: List<Double>): IntRange {
        val pal = trip("dark").palette!!.night
        val bmp = Bitmap.createBitmap(196, 52, Bitmap.Config.ARGB_8888)
        val c = CarClimb(climbAheadM = 0.0, gradePct = null, steepestInM = null, heightsM = heights, steepFrom = null, steepTo = null, windowM = 8000.0)
        CarOverlayPainter.drawShape(Canvas(bmp), RectF(0f, 0f, 196f, 52f), c, pal, 1f)
        val rows = (0 until 52).filter { y -> (20 until 190).any { x -> bmp.getPixel(x, y) == pal.route } }
        return rows.first()..rows.last()
    }

    @Test
    fun aSmallRiseIsDrawnLowAndOnlyARealClimbFillsTheShape() {
        // 2 m of rise over the stretch: a line at the middle (it filled the box from bottom to top before).
        val bump = shapeLineRows((0 until 56).map { 1000.0 + 2.0 * it / 55 })
        assertTrue("$bump", bump.first >= 24 && bump.last <= 29)
        // 50 m: about half the box.
        val half = shapeLineRows((0 until 56).map { 1000.0 + 50.0 * it / 55 })
        assertTrue("$half", half.first in 13..17 && half.last in 33..37)
        // 600 m: all of it, as before.
        val full = shapeLineRows((0 until 56).map { 1000.0 + 600.0 * it / 55 })
        assertTrue("$full", full.first <= 8 && full.last >= 42)
    }

    // ---- the main map's grade badge -------------------------------------------------------------------------------------

    @Test
    fun theGradeOnTheMapBadgeIsNoSmallerThanTheHostsSmallestLineAndThePillHoldsIt() {
        assertTrue(CarOverlayPainter.BADGE_TEXT_SIZE >= CarOverlayPainter.HOST_MIN_TEXT)
        val pal = trip("light").palette!!.night
        // The pill is as high as before (36) and as wide as its text needs: wider than the mock's 68, wider again for two digits.
        val one = CarOverlayPainter.badgeBitmap(9.0, pal, 1f)
        val two = CarOverlayPainter.badgeBitmap(12.0, pal, 1f)
        assertEquals(40, one.height)
        assertTrue("${one.width}", one.width > 72)
        // The picture carries the density it was drawn at (not the phone's), so the map shows it at these sizes on any phone
        // and car: 160 for density 1, and at density 2 twice the pixels marked 320.
        assertEquals(160, one.density)
        val dense = CarOverlayPainter.badgeBitmap(9.0, pal, 2f)
        assertEquals(320, dense.density)
        assertEquals(76, dense.height)
        assertTrue(two.width > one.width)
        val p = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.BADGE_TEXT_SIZE; typeface = Typeface.create(Typeface.DEFAULT, 700, false) }
        assertEquals(34f + p.measureText("12%") + 12f, CarOverlayPainter.badgeWidth("12%", 1f), 0.01f)
        // Density 2: the fixed parts double and the text is as a paint at twice the size measures it (font metrics do not
        // promise that this is exactly twice the density 1 width, so that is only checked loosely).
        val p2 = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.BADGE_TEXT_SIZE * 2f; typeface = Typeface.create(Typeface.DEFAULT, 700, false) }
        assertEquals((34f + 12f) * 2f + p2.measureText("9%"), CarOverlayPainter.badgeWidth("9%", 2f), 0.01f)
        assertEquals(2.0, (CarOverlayPainter.badgeWidth("9%", 2f) / CarOverlayPainter.badgeWidth("9%", 1f)).toDouble(), 0.1)
        // The text is inside the pill: the columns of the last 6 px before the right edge's round end hold no glyph color,
        // and the pill is painted at its middle.
        val w = two.width
        assertEquals(pal.badge, two.getPixel(w / 2, 4))
        for (x in w - 2 - 8 until w - 2 - 4) for (y in 0 until two.height) assertFalse(two.getPixel(x, y) == pal.badgeGlyph)
    }

    // ---- the vehicle's arrow (the main map's position marker) --------------------------------------------------------------

    /** The first and last row, and in a row the first and last column, that hold any paint. */
    private fun paintedRows(b: Bitmap): IntRange {
        val rows = (0 until b.height).filter { y -> (0 until b.width).any { x -> b.getPixel(x, y) != 0 } }
        return rows.first()..rows.last()
    }

    private fun paintedColumns(b: Bitmap, y: Int): List<Int> = (0 until b.width).filter { x -> b.getPixel(x, y) != 0 }

    @Test
    fun theArrowIsAPointedChevronInTheTwoColorsWithItsTipAtTheTop() {
        val fill = 0xFF2F7DF6.toInt()
        val ring = 0xFFFFFFFF.toInt()
        val b = CarOverlayPainter.arrowBitmap(fill, ring, 1f)
        // Not empty, and both colors are there: the fill at the position (the picture's middle), the outline round it.
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        assertTrue(px.any { it == fill })
        assertTrue(px.any { it == ring })
        assertEquals(fill, b.getPixel(b.width / 2, b.height / 2))
        // 34 px from the tip to the tails: clearly bigger than the 28 px dot, smaller than a host button (52 px in this
        // file's stand-in for the host).
        val rows = paintedRows(b)
        val tall = rows.last - rows.first + 1
        assertTrue("$tall", tall in 33..35)
        assertTrue(CarOverlayPainter.ARROW_H > 2 * (CarOverlayPainter.POS_RADIUS + CarOverlayPainter.POS_RING))
        assertTrue(CarOverlayPainter.ARROW_H < 52f)
        // The tip is at the top, on the middle line: the first painted row holds only a few pixels, all at the middle.
        val top = paintedColumns(b, rows.first)
        assertTrue("$top", top.isNotEmpty() && top.size <= 4 && top.all { it >= b.width / 2 - 2 && it <= b.width / 2 + 1 })
        // It widens downwards to two tails with the notch between them: near the last row the middle is empty and there is
        // paint on both sides of it, as far out as the arrow is wide.
        val y = rows.last - 2
        val tail = paintedColumns(b, y)
        assertEquals(0, b.getPixel(b.width / 2, y))
        assertEquals(0, b.getPixel(b.width / 2 - 1, y))
        assertTrue("$tail", tail.any { it < b.width / 2 - 8 } && tail.any { it > b.width / 2 + 8 })
        assertTrue("$tail", tail.last() - tail.first() + 1 in 27..30)
        // The position is the picture's middle (the map turns the picture about it): 19 px under the tip, 15 above the tails.
        assertEquals(19f, b.height / 2f - rows.first, 1f)
        assertEquals(15f, rows.last + 1 - b.height / 2f, 1f)
        // Twice the density: twice the picture, and it says so (the map then shows it pixel for pixel).
        val b2 = CarOverlayPainter.arrowBitmap(fill, ring, 2f)
        val rows2 = paintedRows(b2)
        assertTrue(rows2.last - rows2.first + 1 in 67..69)
        assertEquals(160, b.density)
        assertEquals(320, b2.density)
        // Each theme's own colors: another fill, another picture.
        val other = CarOverlayPainter.arrowBitmap(0xFFC0392B.toInt(), 0xFF000000.toInt(), 1f)
        assertEquals(0xFFC0392B.toInt(), other.getPixel(other.width / 2, other.height / 2))
        assertFalse(other.sameAs(b))
    }

    @Test
    fun theArrowKeepsTheLastHeadingAndThereIsNoneUntilOneIsKnown() {
        // The phone's heading when it gives one.
        assertEquals(45.0, CarMarkerMotion.heading(45.0, 90.0)!!, 0.0)
        assertEquals(45.0, CarMarkerMotion.heading(45.0, null)!!, 0.0)
        // None with this position: the last one known.
        assertEquals(90.0, CarMarkerMotion.heading(null, 90.0)!!, 0.0)
        // None ever: no heading, so no arrow (the dot is drawn), never a made-up direction.
        assertNull(CarMarkerMotion.heading(null, null))
        // Not a number is no heading.
        assertEquals(90.0, CarMarkerMotion.heading(Double.NaN, 90.0)!!, 0.0)
        assertNull(CarMarkerMotion.heading(Double.POSITIVE_INFINITY, null))
        // Headings are kept as 0 up to 360.
        assertEquals(350.0, CarMarkerMotion.heading(-10.0, null)!!, 1e-9)
        assertEquals(0.0, CarMarkerMotion.heading(360.0, null)!!, 1e-9)
        assertEquals(5.0, CarMarkerMotion.heading(725.0, null)!!, 1e-9)
    }

    // ---- the vehicle's movement between positions ------------------------------------------------------------------------

    @Test
    fun theMarkerIsPartOfTheWayBetweenTwoPositionsAndExactlyOnThemAtTheEnds() {
        assertEquals(42.5, CarMarkerMotion.lerp(42.5, 42.6, 0.0), 0.0)
        assertEquals(42.6, CarMarkerMotion.lerp(42.5, 42.6, 1.0), 0.0)
        assertEquals(42.55, CarMarkerMotion.lerp(42.5, 42.6, 0.5), 1e-12)
        assertEquals(-113.775, CarMarkerMotion.lerp(-113.8, -113.7, 0.25), 1e-12)
        // A steady rate: equal shares of the time are equal steps on the ground.
        val steps = (0..10).map { CarMarkerMotion.lerp(10.0, 20.0, it / 10.0) }
        for (i in 1..10) assertEquals(1.0, steps[i] - steps[i - 1], 1e-9)
        // Never past either end.
        assertEquals(42.5, CarMarkerMotion.lerp(42.5, 42.6, -0.2), 0.0)
        assertEquals(42.6, CarMarkerMotion.lerp(42.5, 42.6, 1.2), 0.0)
    }

    @Test
    fun theHeadingTurnsTheShorterWayRound() {
        // 359 to 1 goes through north (2 degrees), not back round through south (358).
        assertEquals(0.0, CarMarkerMotion.lerpHeading(359.0, 1.0, 0.5), 1e-9)
        assertEquals(359.5, CarMarkerMotion.lerpHeading(359.0, 1.0, 0.25), 1e-9)
        assertEquals(0.5, CarMarkerMotion.lerpHeading(359.0, 1.0, 0.75), 1e-9)
        assertEquals(1.0, CarMarkerMotion.lerpHeading(359.0, 1.0, 1.0), 0.0)
        assertEquals(359.0, CarMarkerMotion.lerpHeading(359.0, 1.0, 0.0), 0.0)
        // And the other way: 1 to 359.
        assertEquals(0.0, CarMarkerMotion.lerpHeading(1.0, 359.0, 0.5), 1e-9)
        assertEquals(359.5, CarMarkerMotion.lerpHeading(1.0, 359.0, 0.75), 1e-9)
        // An ordinary turn, right and left.
        assertEquals(45.0, CarMarkerMotion.lerpHeading(0.0, 90.0, 0.5), 1e-9)
        assertEquals(225.0, CarMarkerMotion.lerpHeading(270.0, 180.0, 0.5), 1e-9)
        assertEquals(350.0, CarMarkerMotion.lerpHeading(10.0, 330.0, 0.5), 1e-9)
        // Always 0 up to 360.
        for (i in 0..20) {
            val h = CarMarkerMotion.lerpHeading(350.0, 20.0, i / 20.0)
            assertTrue("$h", h >= 0.0 && h < 360.0)
        }
    }

    @Test
    fun theGlideLastsAsLongAsTheTimeSinceThePositionBeforeUpToTheCap() {
        assertEquals(1200L, CarMarkerMotion.MAX_GLIDE_MS)
        // One position a second: a one second glide, so the marker arrives as the next position does.
        assertEquals(1000L, CarMarkerMotion.durationMs(1000L))
        assertEquals(400L, CarMarkerMotion.durationMs(400L))
        assertEquals(1200L, CarMarkerMotion.durationMs(1200L))
        // A late position: no longer than the cap.
        assertEquals(1200L, CarMarkerMotion.durationMs(2500L))
        assertEquals(0L, CarMarkerMotion.durationMs(-5L))
    }

    @Test
    fun theMarkerJumpsInsteadOfGlidingWhenAGlideWouldLie() {
        fun snaps(first: Boolean = false, gapMs: Long = 1000L, jumpM: Double = 15.0, phaseChanged: Boolean = false, force: Boolean = false) =
            CarMarkerMotion.snaps(first, gapMs, jumpM, phaseChanged, force)
        // The ordinary case, a second and a few meters after the position before: a glide.
        assertFalse(snaps())
        // The first position: there is nowhere to glide from.
        assertTrue(snaps(first = true))
        // More than about three seconds since the position before.
        assertEquals(3000L, CarMarkerMotion.SNAP_GAP_MS)
        assertFalse(snaps(gapMs = 3000L))
        assertTrue(snaps(gapMs = 3001L))
        // No time since the position before: nothing to glide over.
        assertTrue(snaps(gapMs = 0L))
        // More than about 150 m from the position before.
        assertEquals(150.0, CarMarkerMotion.SNAP_JUMP_M, 0.0)
        assertFalse(snaps(jumpM = 150.0))
        assertTrue(snaps(jumpM = 150.1))
        // The trip's phase changed, or the caller says so.
        assertTrue(snaps(phaseChanged = true))
        assertTrue(snaps(force = true))
    }

    @Test
    fun theJumpIsMeasuredInMetersOnTheGround() {
        // A thousandth of a degree of latitude is about 111 m; of longitude at 60 north, half that.
        assertEquals(111.2, CarMarkerMotion.distanceM(42.5, -113.77, 42.501, -113.77), 0.1)
        assertEquals(55.6, CarMarkerMotion.distanceM(60.0, 10.0, 60.0, 10.001), 0.1)
        assertEquals(0.0, CarMarkerMotion.distanceM(42.5, -113.77, 42.5, -113.77), 0.0)
        // A second at highway speed (about 30 m) glides; a new place does not.
        val highway = CarMarkerMotion.distanceM(42.5, -113.77, 42.50027, -113.77)
        assertFalse(CarMarkerMotion.snaps(first = false, gapMs = 1000L, jumpM = highway, phaseChanged = false, force = false))
        val elsewhere = CarMarkerMotion.distanceM(42.5, -113.77, 42.52, -113.77)
        assertTrue(CarMarkerMotion.snaps(first = false, gapMs = 1000L, jumpM = elsewhere, phaseChanged = false, force = false))
        // Either side of the 180 degree line reads as far apart: no glide the long way round the world.
        assertTrue(CarMarkerMotion.distanceM(0.0, 179.9999, 0.0, -179.9999) > CarMarkerMotion.SNAP_JUMP_M)
    }

    // ---- the mini map's destination ---------------------------------------------------------------------------------------

    @Test
    fun theMiniMapsDestinationIsAPlainDotEvenWhenTheSteepestClimbIsAtTheEnd() {
        val pal = trip("parchment").palette!!.night
        val box = RectF(0f, 0f, 220f, 140f)
        fun paint(ov: CarOverview): Bitmap {
            val bmp = Bitmap.createBitmap(220, 140, Bitmap.Config.ARGB_8888)
            CarOverlayPainter.drawMiniMap(Canvas(bmp), box, ov, pal, 1f)
            return bmp
        }
        // The steepest climb ends at the destination (as on the simulator's route): its pill is left out, so 11 px right of
        // the dot's middle (inside where the pill would be, outside the dot) is the card, and the middle is the dot.
        val base = sampleOverview()
        val mid = CarOverview.from(base)!!
        val atEnd = CarOverview.from(base + ("steep" to mapOf("lat" to mid.destLat, "lon" to mid.destLon, "gradePct" to 9.0)))!!
        val end = CarOverlayPainter.project(atEnd.points + listOf(doubleArrayOf(atEnd.steepLat!!, atEnd.steepLon!!)), box, 24f)[atEnd.points.size - 1]
        val a = paint(atEnd)
        assertEquals(pal.destDot, a.getPixel(end[0].toInt(), end[1].toInt()))
        assertEquals(pal.miniBg, a.getPixel(end[0].toInt() + 11, end[1].toInt()))
        assertEquals(pal.miniBg, a.getPixel(end[0].toInt(), end[1].toInt() - 9))
        // A steep point away from the destination keeps its pill.
        val px = CarOverlayPainter.project(mid.points + listOf(doubleArrayOf(mid.steepLat!!, mid.steepLon!!)), box, 24f)
        val b = paint(mid)
        assertEquals(pal.badge, b.getPixel(px.last()[0].toInt() + 11, px.last()[1].toInt()))
        assertEquals(pal.destDot, b.getPixel(px[mid.points.size - 1][0].toInt(), px[mid.points.size - 1][1].toInt()))

        assertFalse(CarOverlayPainter.miniBadgeFits(floatArrayOf(100f, 100f), floatArrayOf(100f, 100f), 1f))
        assertFalse(CarOverlayPainter.miniBadgeFits(floatArrayOf(100f, 100f), floatArrayOf(118f, 110f), 1f))
        assertTrue(CarOverlayPainter.miniBadgeFits(floatArrayOf(100f, 100f), floatArrayOf(123f, 100f), 1f))
        assertTrue(CarOverlayPainter.miniBadgeFits(floatArrayOf(100f, 100f), floatArrayOf(100f, 119f), 1f))
        assertTrue(CarOverlayPainter.miniBadgeFits(floatArrayOf(200f, 200f), floatArrayOf(246f, 200f), 2f))
        assertFalse(CarOverlayPainter.miniBadgeFits(floatArrayOf(200f, 200f), floatArrayOf(240f, 200f), 2f))
    }

    // ---- texts and geometry ---------------------------------------------------------------------------------------------

    @Test
    fun figuresReadInThePhoneUnits() {
        assertEquals("3,350 ft", CarOverlayPainter.climbText(3350.0 / 3.28084, imperial = true))
        assertEquals("1,020 m", CarOverlayPainter.climbText(1021.0, imperial = false))
        assertEquals("2.3 mi", CarOverlayPainter.aheadText(2.3 * 1609.344, imperial = true))
        assertEquals("400 ft", CarOverlayPainter.aheadText(120.0, imperial = true))
        assertEquals("3.7 km", CarOverlayPainter.aheadText(3701.0, imperial = false))
        assertEquals("800 m", CarOverlayPainter.aheadText(790.0, imperial = false))
        assertEquals("9%", CarOverlayPainter.gradeText(8.6))
    }

    @Test
    fun theMiniMapFitsTheRouteInsideTheBoxWithItsPadding() {
        val o = trip("dark").overview!!
        val box = RectF(0f, 0f, 220f, 140f)
        val px = CarOverlayPainter.project(o.points, box, 24f)
        for (p in px) assertTrue(p[0] >= 23.9f && p[0] <= 196.1f && p[1] >= 23.9f && p[1] <= 116.1f)
        // North is up: the destination (north east of the start) is above and right of it.
        assertTrue(px.last()[0] > px.first()[0] && px.last()[1] < px.first()[1])
    }

    @Test
    fun theDrivenPartEndsAtTheFraction() {
        val line = listOf(floatArrayOf(0f, 0f), floatArrayOf(10f, 0f), floatArrayOf(10f, 10f))
        val cut = CarOverlayPainter.cut(line, 0.75)
        assertEquals(3, cut.size)
        assertEquals(10f, cut.last()[0], 0.001f)
        assertEquals(5f, cut.last()[1], 0.001f)
        assertEquals(1, CarOverlayPainter.cut(line, 0.0).size)
        assertEquals(3, CarOverlayPainter.cut(line, 1.0).size)
    }

    @Test
    fun theMainMapsDrivenLineIsCutFromTheRouteGeoJson() {
        val geo = """{"type":"FeatureCollection","features":[
            {"type":"Feature","geometry":{"type":"LineString","coordinates":[[0,0],[1,1]]},"properties":{"alt":true}},
            {"type":"Feature","geometry":{"type":"LineString","coordinates":[[-113.8,42.5],[-113.7,42.5],[-113.6,42.5]]},"properties":{"alt":false}}]}"""
        val coords = CarOverlayGeo.mainRoute(geo)
        assertEquals(3, coords.size)
        val driven = CarOverlayGeo.cut(coords, 0.25)
        assertEquals(2, driven.size)
        assertEquals(-113.75, driven.last()[0], 1e-9)
        assertEquals(CarLink.EMPTY_GEOJSON, CarOverlayGeo.drivenGeoJson(coords, 0.0))
        assertTrue(CarOverlayGeo.drivenGeoJson(coords, 0.5).contains("LineString"))
        assertTrue(CarOverlayGeo.mainRoute("not json").isEmpty())
    }

    @Test
    fun theTacticalPaletteHasNoWhite() {
        val p = trip("tactical").palette!!.night
        for (c in listOf(p.route, p.routeDriven, p.badge, p.badgeGlyph, p.card, p.cardText, p.posFill, p.destDot, p.hatch)) {
            val r = (c shr 16) and 0xFF
            val g = (c shr 8) and 0xFF
            val b = c and 0xFF
            assertTrue("0x${Integer.toHexString(c)} is on the red ramp", r >= g && r >= b && g < 0xC0 && b < 0xC0)
        }
    }

    // ---- the renders ------------------------------------------------------------------------------------------------

    private fun fill(c: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c; style = Paint.Style.FILL }
    private fun line(c: Int, w: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c; style = Paint.Style.STROKE; strokeWidth = w; strokeCap = Paint.Cap.ROUND; strokeJoin = Paint.Join.ROUND }

    /** Stand-in map: a plain fill and a few road lines like the mock (not MapLibre). */
    private fun standInMap(canvas: Canvas, theme: String, pal: CarOverlayColors) {
        val (land, road, road2) = when (theme) {
            "light" -> Triple(0xFFE9E4DC.toInt(), 0xFFFFFFFF.toInt(), 0xFFF4F0EA.toInt())
            "parchment" -> Triple(0xFFE8DBBC.toInt(), 0xFFF6EFDD.toInt(), 0xFFEFE4C8.toInt())
            "tactical" -> Triple(0xFF000000.toInt(), 0xFF3A0B07.toInt(), 0xFF260806.toInt())
            else -> Triple(0xFF1A2026.toInt(), 0xFF2C353E.toInt(), 0xFF232B33.toInt())
        }
        canvas.drawColor(land)
        fun p(f: Path.() -> Unit) = Path().apply(f)
        val ox = 88f
        canvas.drawPath(p { moveTo(ox, 470f); cubicTo(ox + 200, 430f, ox + 380, 500f, ox + 560, 440f); cubicTo(ox + 740, 380f, ox + 900, 360f, 1280f, 400f) }, line(road2, 60f))
        canvas.drawPath(p { moveTo(ox - 20, 120f); lineTo(1290f, 220f) }, line(road, 10f))
        canvas.drawPath(p { moveTo(ox + 440, -20f); lineTo(ox + 520, 600f) }, line(road, 8f))
        canvas.drawPath(p { moveTo(ox, 300f); lineTo(1280f, 330f) }, line(road2, 6f))
        // The route (the mock's main-map line) and the driven part in the faded grey, then the grade badge and the position.
        val route = p {
            moveTo(ox + 680, 560f); cubicTo(ox + 690, 470f, ox + 680, 420f, ox + 720, 360f)
            cubicTo(ox + 760, 300f, ox + 820, 250f, ox + 800, 170f); cubicTo(ox + 780, 90f, ox + 900, 60f, ox + 980, -10f)
        }
        canvas.drawPath(route, line(pal.route, 14f))
        canvas.drawPath(p { moveTo(ox + 680, 560f); cubicTo(ox + 690, 470f, ox + 684, 430f, ox + 708, 392f) }, line(pal.routeDriven, 14f))
        CarOverlayPainter.drawBadge(canvas, ox + 802f, 168f, "9%", pal, 1f)
        canvas.drawCircle(ox + 708f, 392f, 22f, fill((pal.route and 0x00FFFFFF) or 0x40000000))
        canvas.drawCircle(ox + 708f, 392f, 9f, fill(pal.posFill))
        canvas.drawCircle(ox + 708f, 392f, 9f, line(pal.posRing, 3f))
    }

    /** Stand-ins for what Android Auto draws itself, so the placement can be judged (not part of the app). */
    private fun standInHost(canvas: Canvas, pal: CarOverlayColors) {
        val rail = fill(0xFF0D0F11.toInt())
        canvas.drawRect(0f, 0f, 88f, 560f, rail)
        val card = fill(0xFF22303D.toInt())
        canvas.drawRoundRect(RectF(104f, 16f, 484f, 112f), 18f, 18f, card)
        val t = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt(); textSize = 32f; typeface = Typeface.DEFAULT_BOLD }
        canvas.drawText("0.6 mi", 176f, 70f, t)
        val btn = fill(0xFF23292F.toInt())
        for (i in 0..2) canvas.drawCircle(1280f - 16f - 26f, 226f + i * 62f, 26f, btn)
        canvas.drawRoundRect(RectF(1280f - 16f - 190f, 16f, 1280f - 16f, 68f), 26f, 26f, btn)
        canvas.drawRoundRect(RectF(104f, 560f - 16f - 50f, 484f, 560f - 16f), 16f, 16f, btn)
        val t2 = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xFFFFFFFF.toInt(); textSize = 22f; typeface = Typeface.DEFAULT_BOLD }
        canvas.drawText("31 min   15.8 mi   10:12", 122f, 560f - 16f - 16f, t2)
    }

    private fun render(theme: String, climb: Boolean, mini: Boolean, name: String) {
        val t = trip(theme, climb, mini)
        val pal = t.palette!!.night
        val bmp = Bitmap.createBitmap(1280, 560, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        standInMap(canvas, theme, pal)
        standInHost(canvas, pal)
        CarOverlayPainter.draw(canvas, t, dark = true, width = 1280, height = 560, visible = visible, density = 1f)
        val dir = File(System.getProperty("car.aa.out") ?: "build/car_aa").also { it.mkdirs() }
        File(dir, name).outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        // The overlay really painted: the climb card's corner pixel is the card color, the mini map's is its background.
        if (climb) {
            val l = CarOverlayPainter.layout(1280, 560, visible, 1f, true, mini).climb!!
            assertEquals(pal.card, bmp.getPixel((l.left + 100).toInt(), (l.top + 3).toInt()))
        }
    }

    @Test
    fun rendersLight() = render("light", climb = true, mini = true, name = "light.png")

    @Test
    fun rendersParchment() = render("parchment", climb = true, mini = true, name = "parchment.png")

    @Test
    fun rendersDark() = render("dark", climb = true, mini = true, name = "dark.png")

    @Test
    fun rendersTactical() = render("tactical", climb = true, mini = true, name = "tactical.png")

    @Test
    fun rendersDarkWithBothOff() = render("dark", climb = false, mini = false, name = "dark-off.png")
}

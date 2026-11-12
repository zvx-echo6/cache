package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PointF
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
 * The car's two pieces (the route mini map and the climb): parsing of the trip's blocks, the painter's layout rule on the
 * three screens the desktop head unit was run at, the host-card look, and pictures of each screen.
 *
 * SAMPLE DATA: the figures are demo numbers (about 3,350 ft of climb, 9% in 2.3 mi, a route about a third driven), not a real
 * route. The pictures have a flat fill for the map and plain shapes for the host's parts (MapLibre and the host do not render
 * in a JVM test); the pieces on them are the real painter.
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
            "palette" to palette(theme),
        ) + (if (climb) mapOf("climb" to sampleClimb()) else emptyMap()) + (if (mini) mapOf("overview" to sampleOverview()) else emptyMap()),
    )

    // ---- parsing ----------------------------------------------------------------------------------------------------

    @Test
    fun theTripBlocksAreParsed() {
        val t = trip("dark")
        assertFalse(t.overlay.phoneDrive)
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
        assertFalse(t.overlay.phoneDrive)
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
    fun thePhonesDriveScreenIsTheOneThingReadFromTheOverlayPart() {
        fun read(overlay: Any?) = CarTrip.from(mapOf("phase" to "guiding", "overlay" to overlay)).overlay
        assertTrue(read(mapOf("phoneDrive" to true)).phoneDrive)
        assertFalse(read(mapOf("phoneDrive" to false)).phoneDrive)
        // Missing, or not a yes: false.
        assertFalse(read(null).phoneDrive)
        assertFalse(read(emptyMap<String, Any?>()).phoneDrive)
        assertFalse(read(mapOf("phoneDrive" to "yes")).phoneDrive)
        assertFalse(CarTrip.from(mapOf("phase" to "guiding")).overlay.phoneDrive)
        assertEquals(CarOverlaySwitches(phoneDrive = false), CarOverlaySwitches.DEFAULT)
        // The two keys the phone used to send are not read: with both false nothing is different, the pieces are the
        // trip's data, and the one value is all the part holds.
        val old = CarTrip.from(mapOf(
            "phase" to "guiding", "units" to "imperial", "overlay" to mapOf("climb" to false, "miniMap" to false),
            "climb" to sampleClimb(), "overview" to sampleOverview(), "palette" to palette("dark"),
        ))
        assertEquals(CarOverlaySwitches.DEFAULT, old.overlay)
        assertEquals(CarOverlayView.PIECE_MINI_MAP or CarOverlayView.PIECE_CLIMB, CarOverlayView.pieces(old))
        val v = overlayView()
        v.setTrip(old, dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        val fields = CarOverlaySwitches::class.java.declaredFields.filter { !java.lang.reflect.Modifier.isStatic(it.modifiers) }.map { it.name }
        assertEquals(listOf("phoneDrive"), fields)
    }

    // ---- layout maths -----------------------------------------------------------------------------------------------

    // The host's areas as seen on the desktop head unit at density 1, to within a few pixels (the host cards, the turn card's
    // bottom, the arrival card and the map buttons were measured on screenshots; the areas are worked back from them).
    // 1280 x 720: the visible area with the host's map buttons showing, which is also the stable area, and with them hidden.
    private val main = Rect(505, 91, 1177, 697)
    private val mainHidden = Rect(505, 91, 1253, 697)

    // 800 x 480: the host cards run from x 12 to 332, the arrival card from y 305 to 388, the buttons from x 724.
    private val small = Rect(346, 81, 706, 388)
    private val smallHidden = Rect(346, 81, 783, 388)

    // The wide screen, 1280 x 500: the arrival card from y 395 to 478.
    private val wide = Rect(505, 91, 1177, 478)
    private val wideHidden = Rect(505, 91, 1253, 478)

    /** The mock's area (1280 x 560, a rail on the left, no stable area given): no host column to speak of. */
    private val visible = Rect(88, 0, 1280, 560)

    private fun layout(w: Int, h: Int, visible: Rect, stable: Rect, climb: Boolean = true, mini: Boolean = true) =
        CarOverlayPainter.layout(w, h, visible, 1f, showClimb = climb, showMini = mini, stable = stable)

    /** The marker as the map draws it (the arrow pointing up the screen: 30 wide, its tip 19 above the position and its tails
     * 15 below) and the road ahead of it (the route's 12 px casing, up to the top of the area): worked out here from the
     * camera's rule, not from the painter's keep-clear zone. Every piece is also inside the surface. */
    private fun assertClearAndInside(l: CarOverlayPainter.Layout, stable: Rect, w: Int, h: Int) {
        val vx = (stable.left + stable.right) / 2f
        val vy = stable.top + stable.height() * 0.675f
        val marker = RectF(vx - 15f, vy - 19f, vx + 15f, vy + 15f)
        val ahead = RectF(vx - 6f, stable.top.toFloat(), vx + 6f, vy)
        for (r in listOfNotNull(l.climb, l.mini, l.box)) {
            assertFalse("$r is over the vehicle $marker", RectF.intersects(r, marker))
            assertFalse("$r is over the road ahead $ahead", RectF.intersects(r, ahead))
            assertTrue("$r is inside the $w x $h surface", r.left >= 0f && r.top >= 0f && r.right <= w && r.bottom <= h)
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
    fun whichLayoutEachScreenGets() {
        // 1280 x 720: the gap between the turn card (to y 212) and the arrival card (from y 614) is 402, the whole box is 256
        // and wants 40 above and below: one box.
        assertEquals(CarOverlayMode.ONE_BOX, CarOverlayPainter.modeFor(main, 1f))
        val (top, bottom) = CarOverlayPainter.columnGap(main, 1f)
        assertEquals(212f, top, 0.01f)
        assertEquals(614f, bottom, 0.01f)
        val (left, right) = CarOverlayPainter.column(main, 1f)
        assertEquals(91f, left, 0.01f)
        assertEquals(491f, right, 0.01f)
        // 800 x 480: the gap is 103 (202 to 305), far too little for the box: split. The cards are narrower there.
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(small, 1f))
        assertEquals(Pair(202f, 305f), CarOverlayPainter.columnGap(small, 1f))
        assertEquals(Pair(12f, 332f), CarOverlayPainter.column(small, 1f))
        // The wide screen: 183 (212 to 395): split.
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(wide, 1f))
        // The limit is the whole box and its two cushions, whatever is drawn at the moment: 256 + 80 = 336 of gap.
        assertEquals(336f, CarOverlayPainter.MINI_H + CarOverlayPainter.BOX_CLIMB_H + 2 * CarOverlayPainter.BOX_CUSHION_MIN, 0f)
        assertEquals(CarOverlayMode.ONE_BOX, CarOverlayPainter.modeFor(Rect(505, 91, 1177, 91 + 121 + 336 + 83), 1f))
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(Rect(505, 91, 1177, 91 + 121 + 335 + 83), 1f))
        // No left column (the area starts at the screen's edge, as in the host's narrow pane): split.
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(Rect(12, 84, 398, 1200), 1f))
        // A column narrower than the box: split, however tall.
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(Rect(250, 91, 900, 697), 1f))
    }

    @Test
    fun theLayoutDoesNotChangeWhenTheHostShowsOrHidesItsButtons() {
        // The visible area's right edge moves; the stable area, which decides, does not.
        for ((w, h, areas) in listOf(Triple(1280, 720, main to mainHidden), Triple(800, 480, small to smallHidden), Triple(1280, 500, wide to wideHidden))) {
            val (shown, hidden) = areas
            val a = layout(w, h, shown, shown)
            val b = layout(w, h, hidden, shown)
            assertEquals(a.mode, b.mode)
            // What sits in the left column does not move at all.
            assertEquals(a.climb, b.climb)
            if (a.mode == CarOverlayMode.ONE_BOX) assertEquals(a.mini, b.mini)
            // The corner tile keeps its size and its height on the screen, and slides to the wider area's edge.
            if (a.mode == CarOverlayMode.SPLIT) {
                assertEquals(a.mini!!.width(), b.mini!!.width(), 0.01f)
                assertEquals(a.mini!!.top, b.mini!!.top, 0.01f)
                assertEquals(hidden.right.toFloat(), b.mini!!.right, 0.01f)
            }
        }
    }

    @Test
    fun at1280x720OneBoxSitsInTheLeftColumnCentredBetweenTheHostsCards() {
        val l = layout(1280, 720, main, main)
        assertEquals(CarOverlayMode.ONE_BOX, l.mode)
        // On the host cards' left edge, 260 wide; the mini map on top (140), the climb right under it (116).
        assertRect(91f, 285f, 351f, 425f, l.mini)
        assertRect(91f, 425f, 351f, 541f, l.climb)
        assertRect(91f, 285f, 351f, 541f, l.box)
        // The cushion: 73 above (the turn card ends at 212) and 73 below (the arrival card starts at 614), at least 40.
        assertEquals(l.box!!.top - 212f, 614f - l.box!!.bottom, 1f)
        assertTrue(l.box!!.top - 212f >= CarOverlayPainter.BOX_CUSHION_MIN && 614f - l.box!!.bottom >= CarOverlayPainter.BOX_CUSHION_MIN)
        // Left of the visible area, so nowhere near the vehicle; inside the surface.
        assertTrue(l.box!!.right < main.left)
        assertClearAndInside(l, main, 1280, 720)

        // No climb ahead: the mini map alone, exactly where it is with a climb. The box only shrinks from below.
        val m = layout(1280, 720, main, main, climb = false)
        assertEquals(CarOverlayMode.ONE_BOX, m.mode)
        assertNull(m.climb)
        assertEquals(l.mini, m.mini)
        assertRect(91f, 285f, 351f, 425f, m.mini)
        assertEquals(m.mini, m.box)
        // The mini map switched off: the climb alone, exactly where the box's lower part is.
        val c = layout(1280, 720, main, main, mini = false)
        assertNull(c.mini)
        assertEquals(l.climb, c.climb)
        assertRect(91f, 425f, 351f, 541f, c.climb)
        assertEquals(c.climb, c.box)
        // Both off: nothing.
        val none = layout(1280, 720, main, main, climb = false, mini = false)
        assertNull(none.mini)
        assertNull(none.climb)
        assertNull(none.box)
    }

    @Test
    fun theMiniMapDoesNotMoveWhenAClimbAppearsOrEndsOnTheLargeLayout() {
        // The same rectangle with and without a climb, with the host's buttons showing and hidden, at both densities.
        for (area in listOf(main, mainHidden)) {
            assertEquals(layout(1280, 720, area, main).mini, layout(1280, 720, area, main, climb = false).mini)
        }
        val a = Rect(1010, 182, 2354, 1394)
        assertEquals(
            CarOverlayPainter.layout(2560, 1440, a, 2f, showClimb = true, showMini = true, stable = a).mini,
            CarOverlayPainter.layout(2560, 1440, a, 2f, showClimb = false, showMini = true, stable = a).mini,
        )
        // And as painted: the upper part of the picture (down to the divider) is the same pixels with and without a climb.
        val with = drawn(1280, 720, main, trip("light"))
        val without = drawn(1280, 720, main, trip("light", climb = false))
        val mini = layout(1280, 720, main, main).mini!!
        for (y in mini.top.toInt() until mini.bottom.toInt() - 24) for (x in mini.left.toInt() until mini.right.toInt()) {
            if (with.getPixel(x, y) != without.getPixel(x, y)) throw AssertionError("the mini map differs at $x, $y")
        }
        assertEquals(CarOverlayPainter.HOST_CARD_FILL, without.getPixel(mini.left.toInt() + 30, mini.bottom.toInt() - 5))
        assertEquals(0, without.getPixel(mini.left.toInt() + 30, mini.bottom.toInt() + 5))
    }

    @Test
    fun at800x480TheClimbIsAOneLineCardAndTheMiniMapASmallTileInTheCorner() {
        val l = layout(800, 480, small, small)
        assertEquals(CarOverlayMode.SPLIT, l.mode)
        assertNull(l.box)
        // The climb: the host cards' left edge and width (12 to 332), one line (64 high), centred in the gap from 202 to 305.
        assertRect(12f, 222f, 332f, 286f, l.climb)
        assertTrue(l.climb!!.top - 202f >= CarOverlayPainter.LINE_CUSHION_MIN && 305f - l.climb!!.bottom >= CarOverlayPainter.LINE_CUSHION_MIN)
        // The mini map: the full tile (220 x 140) would cover the vehicle at (526, 288), so it is the two-thirds one, its
        // right edge on the visible area's and its bottom 16 above the area's.
        assertRect(559f, 279f, 706f, 372f, l.mini)
        assertClearAndInside(l, small, 800, 480)
        // Never the tall box in the corner: the tile is no higher than the mini map's own height.
        assertTrue(l.mini!!.height() <= CarOverlayPainter.MINI_H)
        // The pieces alone.
        assertNull(layout(800, 480, small, small, climb = false).climb)
        assertRect(559f, 279f, 706f, 372f, layout(800, 480, small, small, climb = false).mini)
        assertNull(layout(800, 480, small, small, mini = false).mini)
        assertRect(12f, 222f, 332f, 286f, layout(800, 480, small, small, mini = false).climb)
    }

    @Test
    fun onTheWideScreenTheClimbIsAOneLineCardAndTheMiniMapAFullTileInTheCorner() {
        val l = layout(1280, 500, wide, wide)
        assertEquals(CarOverlayMode.SPLIT, l.mode)
        assertNull(l.box)
        // The climb: 400 wide like the host's cards, centred in the gap from 212 to 395.
        assertRect(91f, 272f, 491f, 336f, l.climb)
        assertTrue(l.climb!!.top - 212f >= CarOverlayPainter.LINE_CUSHION_MIN && 395f - l.climb!!.bottom >= CarOverlayPainter.LINE_CUSHION_MIN)
        // The mini map: full size, clear of the vehicle at (841, 352), beside the host's buttons.
        assertRect(957f, 322f, 1177f, 462f, l.mini)
        assertClearAndInside(l, wide, 1280, 500)
        // The buttons hidden: the same tile at the wider area's edge.
        assertRect(1033f, 322f, 1253f, 462f, layout(1280, 500, wideHidden, wide).mini)
    }

    @Test
    fun theCornerTileIsFullSizeTwoThirdsOrNotDrawn() {
        // Full size where it clears the vehicle (the wide screen), two thirds where only that does (800 x 480).
        assertEquals(220f, layout(1280, 500, wide, wide).mini!!.width(), 0.01f)
        assertEquals(147f, layout(800, 480, small, small).mini!!.width(), 0.01f)
        assertEquals(93f, layout(800, 480, small, small).mini!!.height(), 0.01f)
        // The size is settled where the buttons show: 800 x 480 keeps the small tile when they hide, though the full one
        // would clear the vehicle then.
        assertRect(636f, 279f, 783f, 372f, layout(800, 480, smallHidden, small).mini)
        // Where neither size clears the vehicle: not drawn. (An area 180 wide: the vehicle's zone is the middle 62 of it.)
        val tight = Rect(346, 81, 526, 388)
        assertNull(layout(800, 480, tight, tight).mini)
        // The host's narrow pane (410 wide, no left column): no climb, the mini map below the vehicle.
        val pane = Rect(12, 84, 398, 613)
        val n = layout(410, 700, pane, pane)
        assertEquals(CarOverlayMode.SPLIT, n.mode)
        assertNull(n.climb)
        assertRect(178f, 457f, 398f, 597f, n.mini)
        assertClearAndInside(n, pane, 410, 700)
    }

    @Test
    fun theOneLineClimbCardNeedsItsCushionAndAColumn() {
        // A gap of 64 + 2 x 12 holds it; one pixel less and no climb is drawn.
        val fitsIn = Rect(346, 81, 706, 81 + 121 + 88 + 83)
        assertNotNull(layout(800, 480, fitsIn, fitsIn).climb)
        val tooShort = Rect(346, 81, 706, 81 + 121 + 87 + 83)
        assertNull(layout(800, 480, tooShort, tooShort).climb)
        // The mock's area (no stable area, the visible one starts 88 from the edge): no column for a card, only the tile.
        val m = CarOverlayPainter.layout(1280, 560, visible, 1f, showClimb = true, showMini = true)
        assertEquals(CarOverlayMode.SPLIT, m.mode)
        assertNull(m.climb)
        assertRect(1060f, 404f, 1280f, 544f, m.mini)
    }

    @Test
    fun theDensityScalesEverything() {
        // 2560 x 1440 at density 2: the 1280 x 720 layout, twice the size.
        val a = Rect(1010, 182, 2354, 1394)
        val l = CarOverlayPainter.layout(2560, 1440, a, 2f, showClimb = true, showMini = true, stable = a)
        assertEquals(CarOverlayMode.ONE_BOX, l.mode)
        assertRect(182f, 570f, 702f, 850f, l.mini)
        assertRect(182f, 850f, 702f, 1082f, l.climb)
        // 1600 x 960 at density 2: the 800 x 480 layout, twice the size.
        val b = Rect(692, 162, 1412, 776)
        val s = CarOverlayPainter.layout(1600, 960, b, 2f, showClimb = true, showMini = true, stable = b)
        assertEquals(CarOverlayMode.SPLIT, s.mode)
        assertEquals(128f, s.climb!!.height(), 0.01f)
        assertEquals(293f, s.mini!!.width(), 0.01f)
    }

    @Test
    fun noPieceCoversTheVehicleOrLeavesTheSurfaceWhateverTheAreas() {
        for (w in 300..1300 step 50) for (h in 250..750 step 50) for (inset in listOf(0, 40, 120, 420)) {
            val stable = Rect(inset, inset / 4, w - inset / 6, h - inset / 8)
            if (stable.width() < 80) continue
            for (extra in listOf(0, 77)) {
                val visible = Rect(stable.left, stable.top, minOf(w, stable.right + extra), stable.bottom)
                for ((climb, mini) in listOf(true to true, true to false, false to true)) {
                    val l = CarOverlayPainter.layout(w, h, visible, 1f, showClimb = climb, showMini = mini, stable = stable)
                    assertClearAndInside(l, stable, w, h)
                    // The tall box is never the corner piece: in the split layout the mini map is a tile of its own size.
                    if (l.mode == CarOverlayMode.SPLIT && l.mini != null) assertTrue(l.mini!!.height() <= CarOverlayPainter.MINI_H)
                    if (l.mode == CarOverlayMode.SPLIT) assertNull(l.box)
                }
            }
        }
    }

    // ---- when the pieces are drawn at all -------------------------------------------------------------------------------

    /** What the View paints right now on the 1280 x 720 screen, as pixels. */
    private fun shot(v: CarOverlayView): IntArray {
        val bmp = Bitmap.createBitmap(1280, 720, Bitmap.Config.ARGB_8888)
        v.paint(Canvas(bmp))
        val px = IntArray(1280 * 720)
        bmp.getPixels(px, 0, 1280, 0, 0, 1280, 720)
        return px
    }

    /** Whether the climb part and the mini map part of the one box are painted (a spot inside each, 1280 x 720). */
    private fun painted(v: CarOverlayView): Pair<Boolean, Boolean> {
        val px = shot(v)
        val l = layout(1280, 720, main, main)
        fun at(r: RectF) = px[(r.top + 8).toInt() * 1280 + (r.left + 40).toInt()] != 0
        return Pair(at(l.climb!!), at(l.mini!!))
    }

    private fun overlayView() = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
        setSurfaceSize(1280, 720)
        setAreas(main, main)
    }

    @Test
    fun neitherPieceIsDrawnWhileTheRouteOverviewIsShown() {
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        v.setOverview(true)
        assertTrue(shot(v).all { it == 0 })
        // Figures that arrive while the overview is up do not bring them back.
        v.setTrip(trip("dark"), dark = true, now = true)
        assertTrue(shot(v).all { it == 0 })
        v.setOverview(false)
        assertEquals(Pair(true, true), painted(v))
        // The painter itself: the overview flag alone stops both pieces, in both layouts.
        for ((w, h, area) in listOf(Triple(1280, 720, main), Triple(800, 480, small))) {
            val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
            CarOverlayPainter.draw(Canvas(bmp), trip("dark"), width = w, height = h, visible = area, density = 1f, stable = area, overview = true)
            val px = IntArray(w * h)
            bmp.getPixels(px, 0, w, 0, 0, w, h)
            assertTrue(px.all { it == 0 })
        }
    }

    @Test
    fun thePiecesGoInTheSameFrameGuidanceStops() {
        val ended = CarTrip.from(mapOf("phase" to "browsing", "palette" to palette("dark")))
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        assertEquals(Pair(true, true), painted(v))
        // Guidance ends within the step time of the last figures: not held back for the next step.
        v.setTrip(ended, dark = true, now = false)
        assertTrue(shot(v).all { it == 0 })

        // New figures were waiting for their step when guidance ended: the step does not bring the pieces back.
        val w = overlayView()
        w.setTrip(trip("dark"), dark = true, now = true)
        w.setTrip(trip("dark"), dark = true, now = false)
        w.setTrip(ended, dark = true, now = false)
        assertTrue(shot(w).all { it == 0 })
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(2 * CarOverlayView.MIN_STEP_MS))
        assertTrue(shot(w).all { it == 0 })

        // Guiding with the route preview's phase or any other: nothing either (only the guiding phase draws).
        val x = overlayView()
        x.setTrip(CarTrip.from(mapOf("phase" to "previewing", "climb" to sampleClimb(), "overview" to sampleOverview(), "palette" to palette("dark"))), dark = true, now = true)
        assertTrue(shot(x).all { it == 0 })
    }

    @Test
    fun eachPieceIsShownAsSoonAsItsOwnDataArrives() {
        // After Start the first guiding trip carries no route shape yet; the mini map's data comes a moment later and the
        // climb's (the elevation) after that. Neither waits for the three-second step.
        val bare = CarTrip.from(mapOf("phase" to "guiding", "units" to "imperial"))
        val miniOnly = CarTrip.from(mapOf("phase" to "guiding", "units" to "imperial", "overview" to sampleOverview(), "palette" to palette("dark")))
        assertEquals(0, CarOverlayView.pieces(bare))
        assertEquals(CarOverlayView.PIECE_MINI_MAP, CarOverlayView.pieces(miniOnly))
        assertEquals(CarOverlayView.PIECE_MINI_MAP or CarOverlayView.PIECE_CLIMB, CarOverlayView.pieces(trip("dark")))
        assertEquals(CarOverlayView.PIECE_MINI_MAP, CarOverlayView.pieces(trip("dark").copy(arrived = true)))
        assertEquals(CarOverlayView.PIECE_CLIMB, CarOverlayView.pieces(trip("dark", mini = false)))
        assertEquals(0, CarOverlayView.pieces(CarTrip.from(mapOf("phase" to "previewing", "overview" to sampleOverview()))))

        val v = overlayView()
        v.setTrip(bare, dark = true, now = false)
        assertTrue(shot(v).all { it == 0 })
        v.setTrip(miniOnly, dark = true, now = false)
        assertEquals(Pair(false, true), painted(v))
        val before = shot(v)
        v.setTrip(trip("dark"), dark = true, now = false)
        assertEquals(Pair(true, true), painted(v))
        // The mini map did not move or change when the climb arrived under it (down to the rounded bottom it had alone).
        val after = shot(v)
        val mini = layout(1280, 720, main, main).mini!!
        for (y in mini.top.toInt() until mini.bottom.toInt() - 24) for (x in mini.left.toInt() until mini.right.toInt()) {
            if (before[y * 1280 + x] != after[y * 1280 + x]) throw AssertionError("the mini map changed at $x, $y")
        }
        // New figures for pieces already showing still wait for their step.
        v.setTrip(CarTrip.from(mapOf(
            "phase" to "guiding", "units" to "imperial", "climb" to sampleClimb(), "palette" to palette("dark"),
            "overview" to (sampleOverview() + ("drivenFraction" to 0.8)),
        )), dark = true, now = false)
        assertTrue(shot(v).contentEquals(after))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarOverlayView.MIN_STEP_MS))
        assertFalse(shot(v).contentEquals(after))
    }

    @Test
    fun aStableAreaThatComesAndGoesDoesNotFlipTheLayout() {
        // What the host reports for a moment when another of its screens covers guidance: no left column.
        val other = Rect(92, 91, 1177, 697)
        assertEquals(CarOverlayMode.SPLIT, CarOverlayPainter.modeFor(other, 1f))
        val v = overlayView()
        v.setTrip(trip("dark"), dark = true, now = true)
        val box = shot(v)
        assertEquals(Pair(true, true), painted(v))
        // The other area arrives and goes again inside the settle time: the same pixels all along, and afterwards.
        v.setAreas(other, other)
        assertTrue(shot(v).contentEquals(box))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarOverlayView.AREA_SETTLE_MS / 2))
        assertTrue(shot(v).contentEquals(box))
        v.setAreas(main, main)
        assertTrue(shot(v).contentEquals(box))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(3 * CarOverlayView.AREA_SETTLE_MS))
        assertTrue(shot(v).contentEquals(box))
        // The other area arrives and stays. It has no left column, so the two pieces do not both fit: a small screen. Nothing
        // changes until the settle time has passed; then the pieces fade out where they are (half a second, nothing pops)
        // and stay away.
        assertEquals(CarExtrasClass.SMALL, CarOverlayPainter.extrasMeasure(1280, 720, other, 1f, other).cls)
        v.setAreas(other, other)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarOverlayView.AREA_SETTLE_MS - 50))
        assertTrue(shot(v).contentEquals(box))
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50 + CarExtrasFade.FADE_MS / 2))
        assertTrue("${opacity(v)}", opacity(v) in 1..254)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarExtrasFade.FADE_MS))
        assertTrue(shot(v).all { it == 0 })
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(3 * CarOverlayView.AREA_SETTLE_MS))
        assertTrue(shot(v).all { it == 0 })
        // The first areas come back and stay: after the settle time the pieces fade in, to the same picture as before.
        v.setAreas(main, main)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarOverlayView.AREA_SETTLE_MS - 50))
        assertTrue(shot(v).all { it == 0 })
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(50 + CarExtrasFade.FADE_MS / 2))
        assertTrue("${opacity(v)}", opacity(v) in 1..254)
        shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(CarExtrasFade.FADE_MS))
        assertTrue(shot(v).contentEquals(box))
    }

    @Test
    fun areasThatKeepTheLayoutAreTakenAtOnce() {
        // The host's buttons hiding moves the split layout's corner tile to the wider area's edge, in the same frame.
        val v = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
            setSurfaceSize(1280, 500)
            setAreas(wide, wide)
        }
        v.setTrip(trip("dark"), dark = true, now = true)
        fun shotWide(): IntArray {
            val bmp = Bitmap.createBitmap(1280, 500, Bitmap.Config.ARGB_8888)
            v.paint(Canvas(bmp))
            return pixelsOf(bmp)
        }
        val before = shotWide()
        assertTrue(before.contentEquals(pixelsOf(drawn(1280, 500, wide, trip("dark")))))
        v.setAreas(wideHidden, wide)
        val after = shotWide()
        assertFalse(after.contentEquals(before))
        assertFalse(after.all { it == 0 })
    }

    // ---- the screen's class, the phone's drive screen, and the fade --------------------------------------------------

    /** How opaque the one box is drawn at 1280 x 720 (a spot on its card fill): 0 not at all, 255 fully. */
    private fun opacity(v: CarOverlayView): Int {
        val l = layout(1280, 720, main, main)
        return shot(v)[(l.mini!!.top + 8).toInt() * 1280 + (l.mini!!.left + 40).toInt()] ushr 24
    }

    private fun idle(ms: Long) = shadowOf(Looper.getMainLooper()).idleFor(java.time.Duration.ofMillis(ms))

    /** A 1280 x 720 car whose stable area is narrower than the usual one: the one box sits where it always does, but takes
     * more than a quarter of the free map. */
    private val inBetween = Rect(505, 91, 650, 697)

    @Test
    fun theScreensClassIsMeasuredFromTheRoomTheCarReports() {
        assertEquals(0.25f, CarOverlayPainter.EXTRAS_BIG_MAX_SHARE, 0f)
        fun m(w: Int, h: Int, stable: Rect, visible: Rect = stable, d: Float = 1f) = CarOverlayPainter.extrasMeasure(w, h, visible, d, stable)
        // 1280 x 720: the whole box fits; it takes 66,560 px of 568,032 px of free map (the stable area and the gap in the
        // host's left column), about 12 %: big.
        val big = m(1280, 720, main)
        assertEquals(CarExtrasClass.BIG, big.cls)
        assertTrue(big.fits)
        assertEquals(66_560f, big.extrasPx, 1f)
        assertEquals(568_032f, big.freePx, 1f)
        assertEquals(0.117f, big.share, 0.001f)
        // The host's buttons hiding widens the visible area only: the same measure, the same class, for the whole drive.
        assertEquals(big, m(1280, 720, main, visible = mainHidden))
        // 1280 x 500 (wide and short): the one-line climb card and the full-size tile fit, about 17 %: big.
        val short = m(1280, 500, wide)
        assertEquals(CarExtrasClass.BIG, short.cls)
        assertEquals(56_400f, short.extrasPx, 1f)
        assertEquals(0.169f, short.share, 0.001f)
        // 800 x 480: only the smaller tile clears the vehicle, so the two do not fit at full size: small, whatever the share.
        val little = m(800, 480, small)
        assertEquals(CarExtrasClass.SMALL, little.cls)
        assertFalse(little.fits)
        // No left column at all (the 410 px pane, or another of the host's screens over guidance): no room for the climb: small.
        assertEquals(CarExtrasClass.SMALL, m(410, 700, Rect(12, 84, 398, 613)).cls)
        assertEquals(CarExtrasClass.SMALL, m(1280, 720, Rect(92, 91, 1177, 697)).cls)
        // The boundary, both sides: the same box in a stable area that ends at x 680 takes 24.9 % (big), at 678 it takes
        // 25.1 % (in-between).
        val under = m(1280, 720, Rect(505, 91, 680, 697))
        val over = m(1280, 720, Rect(505, 91, 678, 697))
        assertTrue(under.fits && over.fits)
        assertTrue("${under.share}", under.share < 0.25f && under.share > 0.249f)
        assertTrue("${over.share}", over.share > 0.25f && over.share < 0.251f)
        assertEquals(CarExtrasClass.BIG, under.cls)
        assertEquals(CarExtrasClass.IN_BETWEEN, over.cls)
        assertEquals(CarExtrasClass.IN_BETWEEN, m(1280, 720, inBetween).cls)
        // The rule on its two figures: exactly a quarter is still big; fitting comes first.
        assertEquals(CarExtrasClass.BIG, CarOverlayPainter.extrasClass(true, 25f, 100f))
        assertEquals(CarExtrasClass.IN_BETWEEN, CarOverlayPainter.extrasClass(true, 25.1f, 100f))
        assertEquals(CarExtrasClass.SMALL, CarOverlayPainter.extrasClass(false, 1f, 100f))
        assertEquals(CarExtrasClass.SMALL, CarOverlayPainter.extrasClass(true, 1f, 0f))
        // Twice the density on twice the pixels is the same screen: the same class and share.
        val dense = m(2560, 1440, Rect(1010, 182, 2354, 1394), d = 2f)
        assertEquals(CarExtrasClass.BIG, dense.cls)
        assertEquals(big.share, dense.share, 0.002f)
        // Where each class puts the extras.
        assertFalse(CarExtrasClass.SMALL.onCar(phoneDrive = false))
        assertFalse(CarExtrasClass.SMALL.onCar(phoneDrive = true))
        assertTrue(CarExtrasClass.IN_BETWEEN.onCar(phoneDrive = false))
        assertFalse(CarExtrasClass.IN_BETWEEN.onCar(phoneDrive = true))
        assertTrue(CarExtrasClass.BIG.onCar(phoneDrive = false))
        assertTrue(CarExtrasClass.BIG.onCar(phoneDrive = true))
    }

    @Test
    fun theFadeWaitsOnePauseThenTakesHalfASecondAndAFlipBackInsideThePauseChangesNothing() {
        assertEquals(2000L, CarExtrasFade.PAUSE_MS)
        assertEquals(500L, CarExtrasFade.FADE_MS)
        // A test clock: plain numbers of milliseconds.
        val f = CarExtrasFade()
        assertEquals(0f, f.alpha(0L), 0f)
        assertNull(f.nextIn(0L))
        // The first frame of a drive: there, at once.
        f.snap(true)
        assertEquals(1f, f.alpha(10_000L), 0f)
        assertNull(f.nextIn(10_000L))
        // Not wanted any more at 10.0 s: nothing for two seconds, then half a second down to nothing.
        f.want(false, 10_000L)
        assertEquals(2000L, f.nextIn(10_000L))
        assertEquals(1f, f.alpha(10_001L), 0f)
        assertEquals(1f, f.alpha(11_999L), 0f)
        assertEquals(1f, f.alpha(12_000L), 0f)
        assertEquals(0L, f.nextIn(12_001L))
        assertEquals(0.75f, f.alpha(12_125L), 0.001f)
        assertEquals(0.5f, f.alpha(12_250L), 0.001f)
        assertEquals(0.02f, f.alpha(12_490L), 0.001f)
        assertEquals(0f, f.alpha(12_500L), 0f)
        assertEquals(0f, f.alpha(60_000L), 0f)
        assertNull(f.nextIn(60_000L))
        // Wanted again: the same pause, the same fade, the other way.
        f.want(true, 60_000L)
        assertEquals(0f, f.alpha(61_999L), 0f)
        assertEquals(0.5f, f.alpha(62_250L), 0.001f)
        assertEquals(1f, f.alpha(62_500L), 0f)
        // A flip and back inside the pause: nothing changes, and nothing is waiting.
        f.want(false, 70_000L)
        assertEquals(1f, f.alpha(71_500L), 0f)
        f.want(true, 71_500L)
        assertNull(f.nextIn(71_500L))
        for (t in 71_500L..76_000L step 100L) assertEquals(1f, f.alpha(t), 0f)
        // A flip during a fade waits its own pause and then fades from where the opacity is: no jump.
        f.want(false, 80_000L)
        assertEquals(0.5f, f.alpha(82_250L), 0.001f)
        f.want(true, 82_250L)
        assertEquals(0f, f.alpha(82_500L), 0f)
        assertEquals(0f, f.alpha(84_249L), 0f)
        assertEquals(0.5f, f.alpha(84_500L), 0.001f)
        assertEquals(1f, f.alpha(84_750L), 0f)
        // Without the pause (the car's own room changed, after its own settle time): the fade begins at once.
        f.want(false, 90_000L, pause = false)
        assertEquals(0.5f, f.alpha(90_250L), 0.001f)
        assertEquals(0f, f.alpha(90_500L), 0f)
        // Asking for what is already wanted changes nothing.
        f.snap(true)
        f.want(true, 95_000L)
        assertNull(f.nextIn(95_000L))
    }

    private fun phone(showing: Boolean) = trip("dark").copy(overlay = CarOverlaySwitches(phoneDrive = showing))

    @Test
    fun onASmallScreenThePiecesAreNeverDrawn() {
        val v = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
            setSurfaceSize(800, 480)
            setAreas(small, small)
        }
        fun blank(): Boolean {
            val bmp = Bitmap.createBitmap(800, 480, Bitmap.Config.ARGB_8888)
            v.paint(Canvas(bmp))
            return pixelsOf(bmp).all { it == 0 }
        }
        // Not on the first frame of the drive, not later, whatever the phone shows. (The painter could place a one-line
        // climb card and a smaller tile here: that is the control.)
        assertFalse(pixelsOf(drawn(800, 480, small, trip("dark"))).all { it == 0 })
        v.setTrip(phone(false), dark = true, now = true)
        assertTrue(blank())
        idle(5000)
        assertTrue(blank())
        v.setTrip(phone(true), dark = true, now = false)
        idle(5000)
        assertTrue(blank())
        v.setTrip(phone(false), dark = true, now = false)
        idle(5000)
        assertTrue(blank())
    }

    @Test
    fun onABigScreenThePiecesStayWhateverThePhoneShows() {
        val v = overlayView()
        v.setTrip(phone(false), dark = true, now = true)
        val box = shot(v)
        assertEquals(Pair(true, true), painted(v))
        v.setTrip(phone(true), dark = true, now = false)
        for (i in 1..10) {
            idle(500)
            assertTrue(shot(v).contentEquals(box))
        }
        // A drive that starts with the phone's drive screen showing: there from the first frame.
        val w = overlayView()
        w.setTrip(phone(true), dark = true, now = true)
        assertTrue(shot(w).contentEquals(box))
    }

    @Test
    fun onAnInBetweenScreenThePiecesFadeOutWhileThePhonesDriveScreenShowsAndBackIn() {
        val v = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
            setSurfaceSize(1280, 720)
            setAreas(inBetween, inBetween)
        }
        // The first frame of the drive, phone not showing: both pieces, fully there.
        v.setTrip(phone(false), dark = true, now = true)
        val box = shot(v)
        assertEquals(Pair(true, true), painted(v))
        assertEquals(255, opacity(v))
        // The phone's drive screen shows for a second and goes again: inside the pause, so nothing on the car changes.
        v.setTrip(phone(true), dark = true, now = false)
        assertTrue(shot(v).contentEquals(box))
        idle(1000)
        assertTrue(shot(v).contentEquals(box))
        v.setTrip(phone(false), dark = true, now = false)
        for (i in 1..8) {
            idle(500)
            assertTrue(shot(v).contentEquals(box))
        }
        // It shows and stays: nothing for two seconds, then both pieces fade together over half a second, then nothing.
        v.setTrip(phone(true), dark = true, now = false)
        idle(CarExtrasFade.PAUSE_MS - 20)
        assertTrue(shot(v).contentEquals(box))
        idle(20 + CarExtrasFade.FADE_MS / 2)
        assertTrue("${opacity(v)}", opacity(v) in 60..195)
        assertEquals(painted(v), Pair(true, true))
        idle(CarExtrasFade.FADE_MS)
        assertTrue(shot(v).all { it == 0 })
        // Trip updates keep coming while it shows: still nothing.
        for (i in 1..5) {
            v.setTrip(phone(true), dark = true, now = false)
            idle(1000)
            assertTrue(shot(v).all { it == 0 })
        }
        // The phone stops showing it: the same pause, then the pieces fade back in, to the picture they were.
        v.setTrip(phone(false), dark = true, now = false)
        idle(CarExtrasFade.PAUSE_MS - 20)
        assertTrue(shot(v).all { it == 0 })
        idle(20 + CarExtrasFade.FADE_MS / 2)
        assertTrue("${opacity(v)}", opacity(v) in 60..195)
        idle(CarExtrasFade.FADE_MS)
        assertTrue(shot(v).contentEquals(box))
        // A drive that starts while the phone's drive screen is showing: not there on the first frame, and no fade.
        val w = CarOverlayView(RuntimeEnvironment.getApplication(), 1f).apply {
            setSurfaceSize(1280, 720)
            setAreas(inBetween, inBetween)
        }
        w.setTrip(phone(true), dark = true, now = true)
        assertTrue(shot(w).all { it == 0 })
        idle(3000)
        assertTrue(shot(w).all { it == 0 })
    }

    @Test
    fun aScreenThatBecomesInBetweenFollowsThePhoneFromThen() {
        // The car's free room narrows (the host's own panel beside the map) but keeps the one box where it is: the class goes
        // from big to in-between, nothing moves, and the phone's drive screen now counts.
        val v = overlayView()
        v.setTrip(phone(true), dark = true, now = true)
        val box = shot(v)
        assertEquals(Pair(true, true), painted(v))
        v.setAreas(inBetween, inBetween)
        assertTrue(shot(v).contentEquals(box))
        idle(CarExtrasFade.PAUSE_MS - 20)
        assertTrue(shot(v).contentEquals(box))
        idle(20 + CarExtrasFade.FADE_MS / 2)
        assertTrue("${opacity(v)}", opacity(v) in 60..195)
        idle(CarExtrasFade.FADE_MS)
        assertTrue(shot(v).all { it == 0 })
    }

    @Test
    fun theFirstLayoutOfACarSessionDoesNotWait() {
        // As the renderer sets a new surface up: no areas yet, then the visible area, then the stable one.
        val v = CarOverlayView(RuntimeEnvironment.getApplication(), 1f)
        v.setSurfaceSize(1280, 720)
        v.setAreas(null, null)
        v.setTrip(trip("dark"), dark = true, now = true)
        v.setAreas(Rect(0, 0, 1280, 720), null)
        v.setAreas(Rect(0, 0, 1280, 720), main)
        assertEquals(Pair(true, true), painted(v))
        v.setAreas(main, main)
        assertEquals(Pair(true, true), painted(v))
    }

    @Test
    fun theOneLineCardsShapeKeepsOffTheCardsCornerAndIsALineWithoutAFill() {
        val r = layout(1280, 500, wide, wide).climb!!
        val withShape = drawn(1280, 500, wide, trip("light"))
        // The same card with no grade to show has no shape (the figure alone, which starts 16 from the edge).
        val noShape = drawn(1280, 500, wide, CarTrip.from(mapOf(
            "phase" to "guiding", "units" to "imperial", "overview" to sampleOverview(), "climb" to (sampleClimb() + ("gradePct" to null)),
        )))
        // The card's first 16 px, its rounded corners among them, hold nothing of the shape: the same pixels with and without.
        for (x in r.left.toInt() until r.left.toInt() + 16) for (y in r.top.toInt() until r.bottom.toInt()) {
            if (withShape.getPixel(x, y) != noShape.getPixel(x, y)) throw AssertionError("the shape reaches the card's edge at $x, $y")
        }
        assertTrue(CarOverlayPainter.LINE_SHAPE_INSET - 6f >= CarOverlayPainter.HOST_CARD_RADIUS)
        // The shape is there, from 28 px in: its line in the route's color.
        val x0 = r.left.toInt() + 28
        assertTrue((x0 until x0 + 84).any { x -> (r.top.toInt() until r.bottom.toInt()).any { y -> withShape.getPixel(x, y) == CarOverlayPainter.ON_DARK_ROUTE } })
        // No fill under the line: just above the shape's bottom edge, right of the start dot, is the plain card. (With the
        // fill, the same spot is not.)
        val spotX = x0 + 12
        val spotY = r.centerY().toInt() + 25
        assertFalse(CarOverlayPainter.LINE_SHAPE_FILLED)
        assertEquals(CarOverlayPainter.HOST_CARD_FILL, withShape.getPixel(spotX, spotY))
        val filled = Bitmap.createBitmap(1280, 500, Bitmap.Config.ARGB_8888)
        CarOverlayPainter.draw(Canvas(filled), trip("light"), width = 1280, height = 500, visible = wide, density = 1f, stable = wide, lineShapeFilled = true)
        assertFalse(filled.getPixel(spotX, spotY) == CarOverlayPainter.HOST_CARD_FILL)
        // The box's own shape (1280 x 720) keeps its fill.
        val box = Bitmap.createBitmap(196, 52, Bitmap.Config.ARGB_8888)
        CarOverlayPainter.drawShape(Canvas(box), RectF(0f, 0f, 196f, 52f), trip("light").climb!!, CarOverlayPainter.HOST_STYLE, 1f)
        assertFalse(box.getPixel(30, 50) == 0)
    }

    @Test
    fun theClimbIsNotDrawnOnArrival() {
        // Arrived, and the trip still carries a climb: what is painted is exactly the mini map alone, in both layouts.
        for ((w, h, area) in listOf(Triple(1280, 720, main), Triple(800, 480, small))) {
            fun pixels(t: CarTrip): IntArray {
                val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                CarOverlayPainter.draw(Canvas(bmp), t, width = w, height = h, visible = area, density = 1f, stable = area)
                val px = IntArray(w * h)
                bmp.getPixels(px, 0, w, 0, 0, w, h)
                return px
            }
            val arrived = pixels(trip("dark").copy(arrived = true))
            assertTrue(arrived.contentEquals(pixels(trip("dark", climb = false))))
            assertFalse(arrived.contentEquals(pixels(trip("dark"))))
            assertTrue(arrived.any { it != 0 })
        }
    }

    // ---- the look: the host's cards, whatever the theme and by day and night ---------------------------------------------

    private fun drawn(w: Int, h: Int, area: Rect, t: CarTrip): Bitmap {
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        CarOverlayPainter.draw(Canvas(bmp), t, width = w, height = h, visible = area, density = 1f, stable = area)
        return bmp
    }

    private fun pixelsOf(b: Bitmap): IntArray {
        val px = IntArray(b.width * b.height)
        b.getPixels(px, 0, b.width, 0, 0, b.width, b.height)
        return px
    }

    @Test
    fun thePiecesAreInTheHostsCardStyle() {
        assertEquals(0xFF242627.toInt(), CarOverlayPainter.HOST_CARD_FILL)
        assertEquals(0xFF45474B.toInt(), CarOverlayPainter.HOST_CARD_EDGE)
        assertEquals(22f, CarOverlayPainter.HOST_CARD_RADIUS, 0f)
        // The one box at 1280 x 720: the card's fill in both parts, its 2 px outline on the left edge, the divider between
        // the parts in the outline's color, nothing outside the box.
        val b = drawn(1280, 720, main, trip("light"))
        val l = layout(1280, 720, main, main)
        val box = l.box!!
        val midY = box.centerY().toInt()
        assertEquals(CarOverlayPainter.HOST_CARD_EDGE, b.getPixel(box.left.toInt(), midY))
        assertEquals(CarOverlayPainter.HOST_CARD_EDGE, b.getPixel(box.left.toInt() + 1, midY))
        assertEquals(CarOverlayPainter.HOST_CARD_FILL, b.getPixel(box.left.toInt() + 5, l.mini!!.top.toInt() + 40))
        assertEquals(CarOverlayPainter.HOST_CARD_FILL, b.getPixel(box.left.toInt() + 5, l.climb!!.top.toInt() + 60))
        assertEquals(CarOverlayPainter.HOST_CARD_EDGE, b.getPixel(box.left.toInt() + 130, l.climb!!.top.toInt()))
        assertEquals(0, b.getPixel(box.left.toInt() - 2, midY))
        assertEquals(0, b.getPixel(box.right.toInt() + 2, midY))
        // The corner is rounded like the host's: the very corner pixel is not painted.
        assertEquals(0, b.getPixel(box.left.toInt() + 1, box.top.toInt() + 1))
        // The split pieces at 800 x 480: each a card of its own in the same fill and outline.
        val s = drawn(800, 480, small, trip("light"))
        val sl = layout(800, 480, small, small)
        for (r in listOf(sl.climb!!, sl.mini!!)) {
            assertEquals(CarOverlayPainter.HOST_CARD_EDGE, s.getPixel(r.left.toInt(), r.centerY().toInt()))
            assertEquals(CarOverlayPainter.HOST_CARD_FILL, s.getPixel(r.left.toInt() + 4, r.centerY().toInt()))
            assertEquals(0, s.getPixel(r.left.toInt() - 2, r.centerY().toInt()))
        }
        // The mini map is drawn for a dark ground: its route is the light blue, somewhere in the box's upper part.
        val part = l.mini!!
        assertTrue((part.left.toInt() until part.right.toInt()).any { x -> (part.top.toInt() until part.bottom.toInt()).any { y -> b.getPixel(x, y) == CarOverlayPainter.ON_DARK_ROUTE } })
    }

    @Test
    fun theThemeAndTheTimeOfDayDoNotChangeThePieces() {
        // The trip's palette does not color the pieces: every theme paints the same pixels, and so does a trip with none.
        for ((w, h, area) in listOf(Triple(1280, 720, main), Triple(800, 480, small))) {
            val light = pixelsOf(drawn(w, h, area, trip("light")))
            for (theme in listOf("parchment", "dark", "tactical")) assertTrue(theme, light.contentEquals(pixelsOf(drawn(w, h, area, trip(theme)))))
            val bare = CarTrip.from(mapOf("phase" to "guiding", "units" to "imperial", "climb" to sampleClimb(), "overview" to sampleOverview()))
            assertNull(bare.palette)
            assertTrue(light.contentEquals(pixelsOf(drawn(w, h, area, bare))))
        }
        // Day and night: the View paints the same in both.
        val day = overlayView().apply { setTrip(trip("light"), dark = false, now = true) }
        val night = overlayView().apply { setTrip(trip("light"), dark = true, now = true) }
        assertTrue(shot(day).contentEquals(shot(night)))
        assertTrue(shot(day).any { it != 0 })
    }

    // ---- the pieces' text: size and contrast --------------------------------------------------------------------------------

    @Test
    fun noTextOnThePiecesIsSmallerThanTheHostsSmallestLine() {
        // The host's smallest line on the guidance screen is 24 px at density 1 (measured on the car simulator).
        assertEquals(24f, CarOverlayPainter.HOST_MIN_TEXT, 0f)
        val sizes = listOf(
            CarOverlayPainter.CLIMB_LABEL_SIZE, CarOverlayPainter.CLIMB_FIGURE_SIZE, CarOverlayPainter.CLIMB_GRADE_SIZE,
            CarOverlayPainter.LINE_FIGURE_SIZE, CarOverlayPainter.LINE_TEXT_SIZE, CarOverlayPainter.BADGE_TEXT_SIZE,
        )
        for (size in sizes) assertTrue("$size", size >= CarOverlayPainter.HOST_MIN_TEXT)
        // In the box the figure is the main thing: 34, well above the two 24 lines.
        assertEquals(34f, CarOverlayPainter.CLIMB_FIGURE_SIZE, 0f)
        assertTrue(CarOverlayPainter.CLIMB_FIGURE_SIZE >= 1.4f * CarOverlayPainter.CLIMB_LABEL_SIZE)
        // The climb part holds its three lines, and the one-line card its line and the shape.
        assertTrue(CarOverlayPainter.CLIMB_FIGURE_DROP >= CarOverlayPainter.CLIMB_FIGURE_SIZE)
        assertTrue(CarOverlayPainter.CLIMB_GRADE_DROP >= CarOverlayPainter.CLIMB_GRADE_SIZE)
        val lines = CarOverlayPainter.BOX_PAD_TOP + CarOverlayPainter.CLIMB_LABEL_SIZE + CarOverlayPainter.CLIMB_FIGURE_DROP + CarOverlayPainter.CLIMB_GRADE_DROP
        assertTrue(lines + 8f <= CarOverlayPainter.BOX_CLIMB_H)
        assertTrue(CarOverlayPainter.LINE_H >= CarOverlayPainter.LINE_FIGURE_SIZE + 2 * CarOverlayPainter.LINE_CUSHION_MIN)
        assertTrue(CarOverlayPainter.LINE_H >= CarOverlayPainter.SHAPE_H)
        // The box is wide enough for its longest lines at those sizes, with a wide margin for another font's metrics.
        val inner = CarOverlayPainter.BOX_W - 2 * CarOverlayPainter.BOX_PAD_X
        val grade = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.CLIMB_GRADE_SIZE; typeface = Typeface.create(Typeface.DEFAULT, 600, false) }
        val figure = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.CLIMB_FIGURE_SIZE; typeface = Typeface.create(Typeface.DEFAULT, 700, false) }
        assertTrue("${grade.measureText("11% in 123.4 mi")}", grade.measureText("11% in 123.4 mi") <= inner)
        assertTrue("${figure.measureText("12,150 ft")}", figure.measureText("12,150 ft") <= inner)
    }

    @Test
    fun theOneLineCardDropsTheShapeFirstThenTheDistance() {
        val f = CarOverlayPainter.LineForm.FIGURE
        // A figure 100 wide, "11% in 23.0 mi" 160 wide, "11%" 45 wide, gaps of 12, a shape of at least 60 that starts 12
        // further in than the text would.
        fun form(avail: Float, gradeDistance: Float? = 160f, grade: Float? = 45f) = CarOverlayPainter.lineForm(avail, 100f, gradeDistance, grade, 1f)
        assertEquals(CarOverlayPainter.LineForm.SHAPE_FIGURE_GRADE_DISTANCE, form(356f))
        assertEquals(CarOverlayPainter.LineForm.FIGURE_GRADE_DISTANCE, form(355f))
        assertEquals(CarOverlayPainter.LineForm.FIGURE_GRADE_DISTANCE, form(272f))
        assertEquals(CarOverlayPainter.LineForm.FIGURE_GRADE, form(271f))
        assertEquals(CarOverlayPainter.LineForm.FIGURE_GRADE, form(157f))
        assertEquals(f, form(156f))
        // No grade to show: the figure alone.
        assertEquals(f, form(400f, gradeDistance = null, grade = null))
        // Twice the density: twice the gaps and the shape.
        assertEquals(CarOverlayPainter.LineForm.SHAPE_FIGURE_GRADE_DISTANCE, CarOverlayPainter.lineForm(712f, 200f, 320f, 90f, 2f))
        assertEquals(CarOverlayPainter.LineForm.FIGURE_GRADE_DISTANCE, CarOverlayPainter.lineForm(711f, 200f, 320f, 90f, 2f))
        // The real texts at the real sizes always leave at least the figure and the grade on the narrowest host card (320).
        val fp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.LINE_FIGURE_SIZE; typeface = Typeface.create(Typeface.DEFAULT, 700, false) }
        val tp = Paint(Paint.ANTI_ALIAS_FLAG).apply { textSize = CarOverlayPainter.LINE_TEXT_SIZE; typeface = Typeface.create(Typeface.DEFAULT, 400, false) }
        val real = CarOverlayPainter.lineForm(320f - 2 * CarOverlayPainter.LINE_PAD_X, fp.measureText("12,150 ft"), tp.measureText("11% in 123.4 mi"), tp.measureText("11%"), 1f)
        assertFalse(real == f)
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
    fun textOnThePiecesReadsWellAboveFourAndAHalfToOne() {
        val p = CarOverlayPainter.HOST_STYLE
        assertEquals(CarOverlayPainter.HOST_CARD_FILL, p.card)
        assertEquals(p.card, p.miniBg)
        assertTrue(contrast(p.cardText, p.card) >= 7.0)
        assertTrue(contrast(p.cardSecondary, p.card) >= 7.0)
        // The mini map's route and the shape's line on the dark ground.
        assertTrue(contrast(p.route, p.miniBg) >= 4.5)
    }

    // ---- the climb's shape is to scale ------------------------------------------------------------------------------------

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
    fun theGradeBadgeMovesUpOffTheDestinationAndTheRoutesEnd() {
        // A badge 80 wide (and 36 high) at its point; the destination marker is 12 in radius and wants 4 of free map.
        fun off(steep: PointF, vararg ends: PointF, d: Float = 1f, w: Float = 80f) = CarOverlayPainter.badgeOffset(steep, ends.toList(), w, d)
        fun covers(steep: PointF, o: PointF, end: PointF, d: Float = 1f, w: Float = 80f): Boolean {
            val badge = RectF(steep.x + o.x - w / 2, steep.y + o.y - 18f * d, steep.x + o.x + w / 2, steep.y + o.y + 18f * d)
            return RectF.intersects(badge, RectF(end.x - 12f * d, end.y - 12f * d, end.x + 12f * d, end.y + 12f * d))
        }
        // The steepest spot at the destination (the route overview's case): the badge was on the dot; it goes straight up,
        // 16 + 18 px, and no longer touches it.
        val p = PointF(600f, 300f)
        assertTrue(covers(p, PointF(0f, 0f), p))
        val up = off(p, PointF(600f, 300f))
        assertEquals(0f, up.x, 0f)
        assertEquals(-34f, up.y, 0.01f)
        assertFalse(covers(p, up, p))
        // Far from the destination and the route's end: where it was.
        assertEquals(0f, off(p, PointF(900f, 300f), PointF(600f, 500f)).y, 0f)
        assertEquals(0f, off(p).y, 0f)
        // Just clear sideways (40 + 16) and just clear below (18 + 16): not moved. One pixel nearer: moved.
        assertEquals(0f, off(p, PointF(656f, 300f)).y, 0f)
        assertFalse(off(p, PointF(655f, 300f)).y == 0f)
        assertEquals(0f, off(p, PointF(600f, 334f)).y, 0f)
        assertFalse(off(p, PointF(600f, 333f)).y == 0f)
        // The destination marker and the route's end a little apart, one above the other: clear of both.
        val dest = PointF(610f, 310f)
        val end = PointF(596f, 270f)
        val both = off(p, dest, end)
        assertFalse(covers(p, both, dest) || covers(p, both, end))
        assertEquals(270f - 16f - 18f - 300f, both.y, 0.01f)
        // Twice the density: twice the sizes.
        val up2 = off(PointF(1200f, 600f), PointF(1200f, 600f), d = 2f, w = 160f)
        assertEquals(-68f, up2.y, 0.01f)
    }

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

    @Test
    fun whileTheMapIsTurnedToTheHeadingTheArrowPointsStraightUpThroughACorner() {
        // Guidance: the camera's bearing is the heading, frame by frame, so the arrow's turn on the screen is 0 before, during
        // and after a corner. (It was the heading itself, sent to the map for every degree and shown late.)
        for (i in 0..30) {
            val heading = CarMarkerMotion.lerpHeading(350.0, 80.0, i / 30.0)
            assertEquals(0.0, CarMarkerMotion.arrowTurn(heading, heading), 0.0)
        }
        // North up (looking at the map, the route overview): the turn is the heading.
        assertEquals(90.0, CarMarkerMotion.arrowTurn(90.0, 0.0), 0.0)
        assertEquals(270.0, CarMarkerMotion.arrowTurn(270.0, 0.0), 0.0)
        // The driver has panned away while guiding: the camera keeps its bearing, the vehicle turns on.
        assertEquals(90.0, CarMarkerMotion.arrowTurn(100.0, 10.0), 1e-9)
        assertEquals(340.0, CarMarkerMotion.arrowTurn(10.0, 30.0), 1e-9)
        assertEquals(20.0, CarMarkerMotion.arrowTurn(10.0, 350.0), 1e-9)
        // How far apart two turns are, the shorter way round.
        assertEquals(2.0, CarMarkerMotion.angleBetween(359.0, 1.0), 1e-9)
        assertEquals(2.0, CarMarkerMotion.angleBetween(1.0, 359.0), 1e-9)
        assertEquals(0.0, CarMarkerMotion.angleBetween(0.0, 360.0), 1e-9)
        assertEquals(180.0, CarMarkerMotion.angleBetween(90.0, 270.0), 1e-9)
        assertEquals(0.5, CarMarkerMotion.angleBetween(10.0, 10.5), 1e-9)
    }

    @Test
    fun theUpArrowShowsOnlyWhileTheCameraIsTurnedToTheHeading() {
        // Guidance: the camera is turned to the heading, the arrow that always points up is the one showing.
        assertTrue(CarMarkerMotion.arrowIsUp(90.0, 90.0))
        assertTrue(CarMarkerMotion.arrowIsUp(359.5, 359.5))
        // The route overview opens (north up) on a road that runs east: the map-tied arrow, which already has the compass
        // heading, shows from that same frame; the up arrow does not.
        assertFalse(CarMarkerMotion.arrowIsUp(90.0, 0.0))
        // And back in guidance.
        assertTrue(CarMarkerMotion.arrowIsUp(90.0, 90.0))
        // A panned map keeps its bearing while the vehicle turns on.
        assertFalse(CarMarkerMotion.arrowIsUp(100.0, 90.0))
        // North up and heading north: up is right there too.
        assertTrue(CarMarkerMotion.arrowIsUp(0.0, 0.0))
    }

    @Test
    fun parkedWithNoCourseTheMarkerIsADotAfterADriveAsBeforeOne() {
        // Guiding: a position without a heading keeps the last one.
        assertEquals(90.0, CarMarkerMotion.heading(null, 90.0, guiding = true)!!, 0.0)
        assertEquals(45.0, CarMarkerMotion.heading(45.0, 90.0, guiding = true)!!, 0.0)
        assertNull(CarMarkerMotion.heading(null, null, guiding = true))
        // Not guiding (the drive is over, the vehicle is parked): a position without a heading has none, whatever the drive's
        // last heading was, so the marker is the dot (it stayed an arrow with the old heading).
        assertNull(CarMarkerMotion.heading(null, 90.0, guiding = false))
        assertNull(CarMarkerMotion.heading(Double.NaN, 90.0, guiding = false))
        // Moving without guidance: the position's own course.
        assertEquals(200.0, CarMarkerMotion.heading(200.0, 90.0, guiding = false)!!, 0.0)
        assertEquals(200.0, CarMarkerMotion.heading(200.0, null, guiding = false)!!, 0.0)
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
    fun aGlidesFramesReachTheMapAboutThirtyTimesASecondAndTheLastOneAlways() {
        assertEquals(30L, CarMarkerMotion.MIN_FRAME_MS)
        // A one second glide on a phone that gives a frame every 8 ms: which frames are sent to the map.
        fun applied(stepMs: Long): List<Long> {
            val out = mutableListOf<Long>()
            var last = 5_000L - 1_000L
            var t = 5_000L
            while (t <= 6_000L) {
                val f = (t - 5_000L) / 1000.0
                if (CarMarkerMotion.appliesFrame(f, t, last)) {
                    out += t
                    last = t
                }
                t += stepMs
            }
            return out
        }
        val fast = applied(8L)
        // 126 frames given, about 32 sent: one every 32 ms.
        assertTrue("${fast.size}", fast.size in 30..34)
        for (i in 1 until fast.size - 1) assertEquals(32L, fast[i] - fast[i - 1])
        // The last frame (the whole way) is sent though it comes 8 ms after the one before: the marker ends on the position.
        assertEquals(6_000L, fast.last())
        assertTrue(fast.last() - fast[fast.size - 2] < CarMarkerMotion.MIN_FRAME_MS)
        // A frame every 16 or 17 ms: every second one, 30 a second.
        val sixty = applied(17L)
        for (i in 1 until sixty.size - 1) assertEquals(34L, sixty[i] - sixty[i - 1])
        // A frame every 40 ms (a slow phone): all of them.
        assertEquals(26, applied(40L).size)
        // The rule itself: too soon is let go, soon enough is sent, the last frame and a frame after a long pause always.
        assertFalse(CarMarkerMotion.appliesFrame(0.5, 1_029L, 1_000L))
        assertTrue(CarMarkerMotion.appliesFrame(0.5, 1_030L, 1_000L))
        assertFalse(CarMarkerMotion.appliesFrame(0.999, 1_008L, 1_000L))
        assertTrue(CarMarkerMotion.appliesFrame(1.0, 1_008L, 1_000L))
        assertTrue(CarMarkerMotion.appliesFrame(1.0, 1_000L, 1_000L))
        assertTrue(CarMarkerMotion.appliesFrame(0.1, 60_000L, 1_000L))
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
    private fun line(c: Int, w: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = c; style = Paint.Style.STROKE; strokeWidth = w; strokeCap = Paint.Cap.BUTT }

    /** One of the three screens for the pictures: its areas and the host's own parts as measured on the desktop head unit
     * (surface pixels at density 1). [bar] is the host's black bar (the rail on the left, or the bar along the bottom). */
    private class Screen(
        val name: String, val w: Int, val h: Int, val shown: Rect, val hidden: Rect, val bar: RectF,
        val turnCard: RectF, val arrivalCard: RectF, val endRoute: RectF, val topButtons: List<PointF>, val mapButtons: List<PointF>,
    )

    private val screens = listOf(
        Screen(
            "1280x720", 1280, 720, Rect(505, 91, 1177, 697), Rect(505, 91, 1253, 697), RectF(0f, 0f, 80f, 720f),
            RectF(92f, 22f, 492f, 212f), RectF(92f, 615f, 492f, 697f), RectF(934f, 22f, 1106f, 86f),
            listOf(PointF(1150f, 54f), PointF(1226f, 54f)), listOf(PointF(1226f, 592f), PointF(1226f, 668f)),
        ),
        Screen(
            "800x480", 800, 480, Rect(346, 81, 706, 388), Rect(346, 81, 783, 388), RectF(0f, 400f, 800f, 480f),
            RectF(12f, 12f, 332f, 202f), RectF(12f, 305f, 332f, 388f), RectF(464f, 12f, 636f, 76f),
            listOf(PointF(680f, 44f), PointF(756f, 44f)), listOf(PointF(756f, 280f), PointF(756f, 356f)),
        ),
        Screen(
            "1280x500-wide", 1280, 500, Rect(505, 91, 1177, 478), Rect(505, 91, 1253, 478), RectF(0f, 0f, 80f, 500f),
            RectF(92f, 22f, 492f, 180f), RectF(92f, 395f, 492f, 478f), RectF(934f, 22f, 1106f, 86f),
            listOf(PointF(1150f, 54f), PointF(1226f, 54f)), listOf(PointF(1226f, 373f), PointF(1226f, 449f)),
        ),
    )

    /** A picture of the overlay on a flat map with stand-ins for the host's parts (plain shapes at the measured places, in
     * the host's card colors; not the host's drawing) and the vehicle where the camera puts it. The pieces themselves are
     * the real painter. Written as PNG for the owner to look at; the CI workflow uploads the folder. */
    private fun picture(
        sc: Screen, buttons: Boolean, climb: Boolean, mini: Boolean = true,
        shapeFilled: Boolean = CarOverlayPainter.LINE_SHAPE_FILLED, shapeInset: Float = CarOverlayPainter.LINE_SHAPE_INSET,
    ): Bitmap {
        val bmp = Bitmap.createBitmap(sc.w, sc.h, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bmp)
        canvas.drawColor(0xFFF7F4EE.toInt())
        // The road: ahead of the vehicle in the route's blue, behind it in grey; the arrow on it.
        val v = CarOverlayPainter.vehiclePoint(sc.shown)
        canvas.drawLine(v.x, 0f, v.x, v.y, line(0xFF1F6FA8.toInt(), 8f))
        canvas.drawLine(v.x, v.y, v.x, sc.h.toFloat(), line(0xFF9AA3AD.toInt(), 8f))
        CarOverlayPainter.drawArrow(canvas, v.x, v.y, 0xFF1F6FA8.toInt(), 0xFFFFFFFF.toInt(), 1f)
        // Cache's pieces (under the host's parts, as on the car).
        val t = trip("light", climb = climb, mini = mini)
        CarOverlayPainter.draw(
            canvas, t, width = sc.w, height = sc.h, visible = if (buttons) sc.shown else sc.hidden, density = 1f, stable = sc.shown,
            lineShapeFilled = shapeFilled, lineShapeInset = shapeInset,
        )
        // The host's parts.
        val card = fill(CarOverlayPainter.HOST_CARD_FILL)
        val edge = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = CarOverlayPainter.HOST_CARD_EDGE; style = Paint.Style.STROKE; strokeWidth = 2f }
        for (r in listOf(sc.turnCard, sc.arrivalCard)) {
            canvas.drawRoundRect(r, 22f, 22f, card)
            canvas.drawRoundRect(RectF(r).apply { inset(1f, 1f) }, 21f, 21f, edge)
        }
        if (buttons) {
            canvas.drawRoundRect(sc.endRoute, 32f, 32f, card)
            for (b in sc.topButtons + sc.mapButtons) canvas.drawCircle(b.x, b.y, 32f, card)
        }
        canvas.drawRect(sc.bar, fill(0xFF000000.toInt()))
        return bmp
    }

    private fun save(bmp: Bitmap, name: String) {
        val dir = File(System.getProperty("car.aa.out") ?: "build/car_overlay").also { it.mkdirs() }
        val f = File(dir, name)
        f.outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
        println("car overlay picture: ${f.absolutePath}")
    }

    @Test
    fun picturesOfTheThreeScreens() {
        for (sc in screens) {
            val l = layout(sc.w, sc.h, sc.shown, sc.shown)
            // The pieces keep off the host's own cards and buttons as measured, with the buttons showing and hidden.
            val host = listOf(sc.turnCard, sc.arrivalCard, sc.bar) + sc.mapButtons.map { RectF(it.x - 32f, it.y - 32f, it.x + 32f, it.y + 32f) }
            for (piece in listOfNotNull(l.climb, l.mini)) for (hr in host) assertFalse("${sc.name}: $piece on the host's $hr", RectF.intersects(piece, hr))
            for (piece in listOfNotNull(layout(sc.w, sc.h, sc.hidden, sc.shown).climb)) for (hr in host) assertFalse(RectF.intersects(piece, hr))
            save(picture(sc, buttons = true, climb = true), "${sc.name}.png")
            save(picture(sc, buttons = false, climb = true), "${sc.name}-buttons-hidden.png")
            save(picture(sc, buttons = true, climb = false), "${sc.name}-no-climb.png")
            save(picture(sc, buttons = true, climb = true, mini = false), "${sc.name}-mini-map-off.png")
            // The one-line card's shape, the two ways it was tidied (the first is what the car draws) and as it was.
            if (sc.name.startsWith("1280x500")) {
                save(picture(sc, buttons = true, climb = true, shapeFilled = false, shapeInset = 28f), "${sc.name}-shape-line-only.png")
                save(picture(sc, buttons = true, climb = true, shapeFilled = true, shapeInset = 28f), "${sc.name}-shape-filled-more-padding.png")
                save(picture(sc, buttons = true, climb = true, shapeFilled = true, shapeInset = 16f), "${sc.name}-shape-as-it-was.png")
            }
            // The picture really holds the pieces: the card fill at a spot inside each.
            val p = picture(sc, buttons = true, climb = true)
            for (piece in listOfNotNull(l.climb, l.mini)) {
                assertEquals(sc.name, CarOverlayPainter.HOST_CARD_FILL, p.getPixel(piece.left.toInt() + 30, piece.bottom.toInt() - 4))
            }
        }
        assertEquals(CarOverlayMode.ONE_BOX, layout(1280, 720, screens[0].shown, screens[0].shown).mode)
        assertEquals(CarOverlayMode.SPLIT, layout(800, 480, screens[1].shown, screens[1].shown).mode)
        assertEquals(CarOverlayMode.SPLIT, layout(1280, 500, screens[2].shown, screens[2].shown).mode)
    }
}

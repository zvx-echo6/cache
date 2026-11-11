package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
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
        assertEquals(560f - 16f - 58f, c.bottom, 0.01f)
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

    /** The marker as the map draws it (radius and ring) and the road ahead of it (the route's 12 px casing, up to the top of
     * the area): worked out here from the camera's rule, not from the painter's keep-clear zone. */
    private fun assertVehicleClear(l: CarOverlayPainter.Layout, stable: Rect) {
        val vx = (stable.left + stable.right) / 2f
        val vy = stable.top + stable.height() * 0.675f
        val marker = RectF(vx - 14f, vy - 14f, vx + 14f, vy + 14f)
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
        assertTrue(keep.contains(v.x, v.y) && keep.top == 91f && keep.bottom >= v.y + 14f && keep.left <= v.x - 14f && keep.right >= v.x + 14f)
    }

    @Test
    fun at1280x720TheApprovedLayoutDoesNotMove() {
        // The host's buttons showing: the visible area is the stable area.
        val shown = CarOverlayPainter.layout(1280, 720, mainStable, 1f, showClimb = true, showMini = true, stable = mainStable)
        assertEquals(520f, shown.climb!!.left, 0.51f)
        assertEquals(526f, shown.climb!!.top, 0.51f)
        assertEquals(845f, shown.climb!!.right, 0.51f)
        assertRect(861f, 541f, 1081f, 681f, shown.mini)
        assertVehicleClear(shown, mainStable)
        // The buttons hidden: the visible area reaches 77 px further right, the vehicle stays.
        val hidden = CarOverlayPainter.layout(1280, 720, Rect(504, 91, 1258, 697), 1f, showClimb = true, showMini = true, stable = mainStable)
        assertEquals(520f, hidden.climb!!.left, 0.51f)
        assertEquals(526f, hidden.climb!!.top, 0.51f)
        assertEquals(900f, hidden.climb!!.right, 0.51f)
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
        assertTrue(c.right < 843f - 14f)
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
        assertTrue(n.mini!!.top >= CarOverlayPainter.vehiclePoint(narrow).y + 14f)
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

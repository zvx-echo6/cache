package com.happylittlellc.cache.car

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.PointF
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import kotlin.math.abs
import kotlin.math.ceil
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt
import kotlin.math.sqrt

/**
 * Paints the two Cache-drawn pieces on the car's map (the approved design, mockup-androidauto): the climb-ahead card at the
 * bottom left and the route mini map at the bottom right. Pure drawing: a Canvas, the trip's blocks, a palette, a size, the
 * visible area and the density go in; nothing is read from the car, nothing moves, nothing is interactive.
 *
 * Sizes are the mock's pixels at density 1.0 (a 1280 x 560 screen), scaled by [density]. The pieces stay inside the visible
 * area the host reports (SurfaceCallback.onVisibleAreaChanged), because the host draws its own guidance card, action strip and
 * map buttons over the rest of the surface.
 *
 * The pieces never lie over the vehicle. While guiding, the camera (CarMapRenderer.follow) puts the position marker at
 * [vehiclePoint] of the stable area, and the road ahead runs up the screen from it. [keepClear] is that marker and the column
 * above it; a piece that would reach into it gives way: the mini map is not drawn, the climb card ends short of it or, when
 * that leaves too little for its text and shape, is not drawn either. The camera is not moved to make room: on a short screen
 * the road ahead is worth more than a card.
 */
object CarOverlayPainter {
    // ---- layout (mock pixels at density 1.0) ---------------------------------------------------------------------
    const val MARGIN = 16f
    const val CLIMB_W = 380f
    const val CLIMB_H = 121f
    const val CLIMB_PAD_X = 18f
    const val CLIMB_PAD_Y = 14f
    const val CLIMB_TEXT_W = 168f
    const val CLIMB_GAP = 16f
    const val SHAPE_W = 196f
    const val SHAPE_H = 52f

    /** The narrowest shape still worth drawing beside the text. */
    const val SHAPE_MIN_W = 60f

    /** The smallest text the host itself draws on the guidance screen (the second line of its estimate card and the next
     * step: 24 px at density 1.0, measured on the car simulator). No text on the pieces is smaller. */
    const val HOST_MIN_TEXT = 24f

    /** The climb card's three lines: the label, the figure (bold) and the grade line (semibold). The mock had 13, 26 and 15;
     * the label and the grade line were raised to the host's smallest size, and the figure to 34 so it still reads as the
     * main thing beside them. */
    const val CLIMB_LABEL_SIZE = HOST_MIN_TEXT
    const val CLIMB_FIGURE_SIZE = 34f
    const val CLIMB_GRADE_SIZE = HOST_MIN_TEXT

    /** From the label's baseline down to the figure's, and from the figure's down to the grade line's. */
    const val CLIMB_FIGURE_DROP = 37f
    const val CLIMB_GRADE_DROP = 29f

    /** Free map under the climb card. With the mock's 97 high card this was 58 (room for the host's travel-estimate card);
     * the card grew 24 downwards for its larger text, so its top edge stays where it was. The host keeps its own cards out
     * of the visible area, so nothing of the host's is under the card. */
    const val ETA_CLEARANCE = 34f
    const val MINI_W = 220f
    const val MINI_H = 140f

    /** The mini map keeps clear of the map buttons at the right edge. */
    const val MINI_RIGHT_CLEARANCE = 84f

    /** While guiding the camera leaves this share of the area's height free above the position, so more of the road ahead shows. */
    const val GUIDANCE_TOP_SHARE = 0.35

    /** The main map's position marker while no heading was ever known (the car-pos-dot layer): its radius and its ring, which
     * is drawn outside the radius. */
    const val POS_RADIUS = 10f
    const val POS_RING = 4f

    /** The main map's position marker once a heading is known (the car-pos layer): an arrowhead, [ARROW_W] wide and [ARROW_H]
     * from its tip to its two tails, outline included. The position is the point [ARROW_AHEAD] behind the tip, on the middle
     * line: the arrow turns about it. */
    const val ARROW_W = 30f
    const val ARROW_H = 34f
    const val ARROW_AHEAD = 19f
    const val ARROW_OUTLINE = 3f

    /** How deep the notch at the back is cut, from the tails towards the tip. */
    const val ARROW_NOTCH = 8.5f

    /** How far the marker reaches from the position, sideways and downwards on the screen. While guiding the map is turned to
     * the heading, so the arrow points up the screen: half its width to each side, and its tails below. Neither is smaller than
     * the dot, which is drawn instead of the arrow while no heading is known. */
    const val MARKER_SIDE = ARROW_W / 2f
    const val MARKER_BELOW = ARROW_H - ARROW_AHEAD

    /** Free map kept on each side of the marker and of the road ahead of it. */
    const val VEHICLE_SIDE = 16f

    /** The extra top padding of the guidance camera for [area] (the stable area, as CarMapRenderer.follow uses it). */
    fun guidanceTopInset(area: Rect): Double = area.height() * GUIDANCE_TOP_SHARE

    /** Where the guidance camera draws the position: the middle of [area] sideways, and the middle of what is left of its
     * height under [guidanceTopInset]. */
    fun vehiclePoint(area: Rect): PointF =
        PointF((area.left + area.right) / 2f, area.top + area.height() * ((1.0 + GUIDANCE_TOP_SHARE) / 2.0).toFloat())

    /** What no piece may cover: the position marker with [VEHICLE_SIDE] on each side, and the column above it (the road
     * ahead) up to the top of [area]. Under the marker is road already driven, so a piece may begin right below it. */
    fun keepClear(area: Rect, density: Float): RectF {
        val v = vehiclePoint(area)
        val half = (MARKER_SIDE + VEHICLE_SIDE) * density
        return RectF(v.x - half, area.top.toFloat(), v.x + half, v.y + MARKER_BELOW * density)
    }

    /** Where the two pieces go, in surface pixels; null when a piece is off or does not fit. */
    data class Layout(val climb: RectF?, val mini: RectF?)

    /** [visible] is where the pieces may go (it changes as the host shows and hides its buttons); [stable] is the area the
     * camera places the vehicle in. Each falls back to the other, then to the whole surface, as CarMapRenderer.follow does. */
    fun layout(width: Int, height: Int, visible: Rect?, density: Float, showClimb: Boolean, showMini: Boolean, stable: Rect? = null): Layout {
        val full = Rect(0, 0, width, height)
        val area = Rect(visible ?: stable ?: full).also { it.intersect(0, 0, width, height) }
        if (area.isEmpty) return Layout(null, null)
        val d = density
        val keep = keepClear(stable ?: visible ?: full, d)
        var mini: RectF? = null
        if (showMini) {
            val w = MINI_W * d
            val h = MINI_H * d
            val right = area.right - (MARGIN + MINI_RIGHT_CLEARANCE) * d
            val r = RectF(right - w, area.bottom - MARGIN * d - h, right, area.bottom - MARGIN * d)
            if (r.left >= area.left && r.top >= area.top && !RectF.intersects(r, keep)) mini = r
        }
        var climb: RectF? = null
        if (showClimb) {
            val left = area.left + MARGIN * d
            var w = CLIMB_W * d
            // Narrow screens: give way to the mini map, down to a card that still holds its text and shape.
            if (mini != null) w = min(w, mini.left - left - MARGIN * d)
            w = min(w, area.right - MARGIN * d - left)
            val h = CLIMB_H * d
            val bottom = area.bottom - (MARGIN + ETA_CLEARANCE) * d
            // The vehicle or the road ahead would be under the card: the card ends short of them.
            if (RectF.intersects(RectF(left, bottom - h, left + w, bottom), keep)) w = keep.left - left
            if (w >= (CLIMB_PAD_X * 2 + CLIMB_TEXT_W + CLIMB_GAP + SHAPE_MIN_W) * d && bottom - h >= area.top) climb = RectF(left, bottom - h, left + w, bottom)
        }
        return Layout(climb, mini)
    }

    /** Both pieces for [trip] (the switches are the trip's), in the car's day or night colors. Nothing is drawn unless the
     * trip is guiding, and nothing while the route overview screen is up ([overview]): the mini map would repeat what that
     * screen's map already shows, and both pieces would sit on the route and the vehicle there. */
    fun draw(canvas: Canvas, trip: CarTrip, dark: Boolean, width: Int, height: Int, visible: Rect?, density: Float, stable: Rect? = null, overview: Boolean = false) {
        val pal = trip.palette?.forMode(dark) ?: return
        if (!trip.guiding || overview) return
        val l = layout(width, height, visible, density, showClimb = trip.overlay.climb && trip.climb != null, showMini = trip.overlay.miniMap && trip.overview != null, stable = stable)
        val climb = trip.climb
        if (l.climb != null && climb != null) drawClimbCard(canvas, l.climb, climb, trip.imperial, pal, density)
        val ov = trip.overview
        if (l.mini != null && ov != null) drawMiniMap(canvas, l.mini, ov, pal, density)
    }

    // ---- the climb card ----------------------------------------------------------------------------------------------

    fun climbText(meters: Double, imperial: Boolean): String {
        val v = if (imperial) meters * 3.28084 else meters
        val r = (v / 10.0).roundToInt() * 10
        return "%,d %s".format(java.util.Locale.US, r, if (imperial) "ft" else "m")
    }

    /** "2.3 mi" or "400 ft" (metric: "3.5 km" or "800 m"). */
    fun aheadText(meters: Double, imperial: Boolean): String {
        if (imperial) {
            val mi = meters / 1609.344
            if (mi >= 0.1) return "%.1f mi".format(java.util.Locale.US, mi)
            return "${(meters * 3.28084 / 50.0).roundToInt() * 50} ft"
        }
        if (meters >= 1000) return "%.1f km".format(java.util.Locale.US, meters / 1000.0)
        return "${(meters / 50.0).roundToInt() * 50} m"
    }

    fun gradeText(gradePct: Double): String = "${gradePct.roundToInt()}%"

    private fun fill(color: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply { this.color = color; style = Paint.Style.FILL }

    private fun stroke(color: Int, w: Float) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        style = Paint.Style.STROKE
        strokeWidth = w
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    private fun text(color: Int, sizePx: Float, weight: Int) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        this.color = color
        textSize = sizePx
        typeface = Typeface.create(Typeface.DEFAULT, weight, false)
    }

    private fun withAlpha(c: Int, a: Float): Int = (c and 0x00FFFFFF) or ((a.coerceIn(0f, 1f) * 255).roundToInt() shl 24)

    fun drawClimbCard(canvas: Canvas, r: RectF, c: CarClimb, imperial: Boolean, pal: CarOverlayColors, d: Float) {
        canvas.drawRoundRect(r, 16f * d, 16f * d, fill(pal.card))
        val x0 = r.left + CLIMB_PAD_X * d
        // Text column: the label, the figure in bold, the grade line in semibold, one under the other as in the mock.
        val labelPaint = text(pal.cardSecondary, CLIMB_LABEL_SIZE * d, 400)
        val figurePaint = text(pal.cardText, CLIMB_FIGURE_SIZE * d, 700)
        val gradePaint = text(pal.cardText, CLIMB_GRADE_SIZE * d, 600)
        val label = "Climb ahead"
        val figure = climbText(c.climbAheadM, imperial)
        var y = r.top + (CLIMB_PAD_Y + CLIMB_LABEL_SIZE) * d
        canvas.drawText(label, x0, y, labelPaint)
        y += CLIMB_FIGURE_DROP * d
        canvas.drawText(figure, x0, y, figurePaint)
        var textW = max(labelPaint.measureText(label), figurePaint.measureText(figure))
        val g = c.gradePct
        val into = c.steepestInM
        if (g != null && into != null) {
            val grade = "${gradeText(g)} in ${aheadText(into, imperial)}"
            y += CLIMB_GRADE_DROP * d
            canvas.drawText(grade, x0, y, gradePaint)
            textW = max(textW, gradePaint.measureText(grade))
        }
        // The shape takes what the text leaves (a long figure pushes it right), and is left out when that is too little.
        val shapeRight = r.right - CLIMB_PAD_X * d
        val shapeW = min(SHAPE_W * d, shapeRight - (x0 + max(CLIMB_TEXT_W * d, textW) + CLIMB_GAP * d))
        if (shapeW < SHAPE_MIN_W * d * 0.5f) return
        val shape = RectF(shapeRight - shapeW, r.centerY() - SHAPE_H * d / 2, shapeRight, r.centerY() + SHAPE_H * d / 2)
        drawShape(canvas, shape, c, pal, d)
    }

    /** The shape of the road ahead, no axes: lightly filled under a line, a dot at the start, the steepest stretch hatched. */
    fun drawShape(canvas: Canvas, box: RectF, c: CarClimb, pal: CarOverlayColors, d: Float) {
        val n = c.heightsM.size
        val lo = c.heightsM.min()
        val hi = c.heightsM.max()
        val span = max(hi - lo, 1.0)
        // The mock's shape runs from y 48 (low) to y 5 (high) in a 52 high box; a flat road sits in the lower middle.
        val top = box.top + 5f * d
        val bottomY = box.top + 48f * d
        fun xAt(i: Int) = box.left + box.width() * i / (n - 1)
        fun yAt(i: Int): Float = if (hi - lo < 1.0) (top + bottomY) / 2f else (bottomY - ((c.heightsM[i] - lo) / span).toFloat() * (bottomY - top))
        val line = Path().apply {
            moveTo(xAt(0), yAt(0))
            for (i in 1 until n) lineTo(xAt(i), yAt(i))
        }
        val area = Path(line).apply {
            lineTo(xAt(n - 1), box.bottom)
            lineTo(xAt(0), box.bottom)
            close()
        }
        canvas.drawPath(area, fill(withAlpha(pal.route, 0.22f)))
        val from = c.steepFrom
        val to = c.steepTo
        if (from != null && to != null && to > from) {
            val steep = Path().apply {
                moveTo(xAt(from), yAt(from))
                for (i in from + 1..to) lineTo(xAt(i), yAt(i))
                lineTo(xAt(to), box.bottom)
                lineTo(xAt(from), box.bottom)
                close()
            }
            canvas.save()
            canvas.clipPath(steep)
            val hp = stroke(withAlpha(pal.hatch, 0.6f), 2f * d).also { it.strokeCap = Paint.Cap.BUTT }
            var x = xAt(from) - box.height()
            val end = xAt(to)
            while (x < end) {
                canvas.drawLine(x, box.bottom, x + box.height(), box.top, hp)
                x += 6f * d * 1.4142f
            }
            canvas.restore()
        }
        canvas.drawPath(line, stroke(pal.route, 3f * d))
        canvas.drawCircle(xAt(0), yAt(0), 5f * d, fill(pal.posFill))
        canvas.drawCircle(xAt(0), yAt(0), 5f * d, stroke(pal.posRing, 2f * d))
    }

    // ---- the grade badge (the main map's and the mini map's) --------------------------------------------------------------

    /** The grade on the main map's badge: the host's smallest text size, like the climb card's lines (the mock had 18). */
    const val BADGE_TEXT_SIZE = HOST_MIN_TEXT

    /** The pill's height with the percent, and where the percent starts from its left edge (after the slope triangle). */
    const val BADGE_H = 36f
    const val BADGE_TEXT_X = 34f
    const val BADGE_PAD_RIGHT = 12f

    private fun badgeText(color: Int, d: Float) = text(color, BADGE_TEXT_SIZE * d, 700)

    /** The pill's width with [percent] on it: the triangle, the text as it measures, and the padding. (The mock's pill was a
     * fixed 68 for 18 px text; at 24 the text is wider, and a two-digit grade wider again, so the pill follows the text.) */
    fun badgeWidth(percent: String, d: Float): Float = (BADGE_TEXT_X + BADGE_PAD_RIGHT) * d + badgeText(0, d).measureText(percent)

    /** A pill with the slope triangle and, when [percent] is set, the grade. Centered on (cx, cy); the pill is 36 high with the
     * percent ([badgeWidth] wide), 20 high without (28 wide), at density 1. */
    fun drawBadge(canvas: Canvas, cx: Float, cy: Float, percent: String?, pal: CarOverlayColors, d: Float) {
        val h = (if (percent != null) BADGE_H else 20f) * d
        val w = if (percent != null) badgeWidth(percent, d) else 28f * d
        val box = RectF(cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2)
        canvas.drawRoundRect(box, h / 2, h / 2, fill(pal.badge))
        canvas.drawRoundRect(box, h / 2, h / 2, stroke(pal.badgeEdge, max(1f, 1.5f * d)))
        val tri = Path()
        if (percent != null) {
            val tx = box.left + 12f * d
            tri.moveTo(tx, cy + 8f * d); tri.lineTo(tx + 16f * d, cy - 8f * d); tri.lineTo(tx + 16f * d, cy + 8f * d); tri.close()
            canvas.drawPath(tri, fill(pal.badgeGlyph))
            // The baseline is half the digits' height (about 0.71 of the size) under the middle.
            canvas.drawText(percent, box.left + BADGE_TEXT_X * d, cy + BADGE_TEXT_SIZE * 0.355f * d, badgeText(pal.badgeGlyph, d))
        } else {
            val tx = cx - 7f * d
            tri.moveTo(tx, cy + 5f * d); tri.lineTo(tx + 10f * d, cy - 5f * d); tri.lineTo(tx + 10f * d, cy + 5f * d); tri.close()
            canvas.drawPath(tri, fill(pal.badgeGlyph))
        }
    }

    /** The main map's badge as a picture (a MapLibre symbol image). */
    fun badgeBitmap(gradePct: Double, pal: CarOverlayColors, d: Float): Bitmap {
        val w = ceil(badgeWidth(gradeText(gradePct), d)).toInt() + 4
        val h = (BADGE_H * d).toInt() + 4
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawBadge(Canvas(bmp), w / 2f, h / 2f, gradeText(gradePct), pal, d)
        return bmp
    }

    // ---- the vehicle's arrow (the main map's position marker) ------------------------------------------------------------

    /** The arrowhead pointing up, with the position at (cx, cy): a pointed chevron with a notch at the back, filled with
     * [fill] and outlined with [outline]. The outline is drawn on the shape's edge with round corners, so the shape's own
     * corners sit half an outline inside the sizes above. */
    fun drawArrow(canvas: Canvas, cx: Float, cy: Float, fill: Int, outline: Int, d: Float) {
        val o = ARROW_OUTLINE / 2f
        val tipY = cy - (ARROW_AHEAD - o) * d
        val tailY = cy + (MARKER_BELOW - o) * d
        val wing = (MARKER_SIDE - o) * d
        val p = Path()
        p.moveTo(cx, tipY)
        p.lineTo(cx + wing, tailY)
        p.lineTo(cx, tailY - ARROW_NOTCH * d)
        p.lineTo(cx - wing, tailY)
        p.close()
        canvas.drawPath(p, fill(fill))
        canvas.drawPath(p, stroke(outline, ARROW_OUTLINE * d))
    }

    /** The arrow as a picture (a MapLibre symbol image), unrotated: the tip at the top. The position is the picture's middle,
     * which is what the map puts on the position and turns the picture about; that is why there is empty room under the tails.
     * The picture says it is drawn at [d], so the map shows it pixel for pixel on a map of that density. */
    fun arrowBitmap(fill: Int, outline: Int, d: Float): Bitmap {
        val w = ceil(ARROW_W * d).toInt() + 2 * ARROW_BITMAP_PAD
        val h = ceil(2 * ARROW_AHEAD * d).toInt() + 2 * ARROW_BITMAP_PAD
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawArrow(Canvas(bmp), w / 2f, h / 2f, fill, outline, d)
        bmp.density = (160f * d).roundToInt()
        return bmp
    }

    /** Empty pixels around the arrow in its picture. */
    const val ARROW_BITMAP_PAD = 2

    // ---- the route mini map --------------------------------------------------------------------------------------------

    /** The route's points in the box, as pixels: equirectangular (longitude scaled by cos latitude), one scale, centered, with
     * [pad] around. No tiles, no labels. */
    fun project(points: List<DoubleArray>, box: RectF, pad: Float): List<FloatArray> {
        val lat0 = points.map { it[0] }.average()
        val kx = cos(Math.toRadians(lat0))
        val xs = points.map { it[1] * kx }
        val ys = points.map { -it[0] }
        val minX = xs.min(); val maxX = xs.max(); val minY = ys.min(); val maxY = ys.max()
        val w = max(maxX - minX, 1e-9); val h = max(maxY - minY, 1e-9)
        val aw = box.width() - 2 * pad; val ah = box.height() - 2 * pad
        val s = min(aw / w, ah / h)
        val ox = box.left + pad + (aw - w * s) / 2; val oy = box.top + pad + (ah - h * s) / 2
        return points.indices.map { floatArrayOf((ox + (xs[it] - minX) * s).toFloat(), (oy + (ys[it] - minY) * s).toFloat()) }
    }

    /** The first [fraction] of the polyline (by length) as points, ending exactly at that fraction. */
    fun cut(pts: List<FloatArray>, fraction: Double): List<FloatArray> {
        if (pts.size < 2 || fraction <= 0.0) return pts.take(1)
        val cum = DoubleArray(pts.size)
        for (i in 1 until pts.size) cum[i] = cum[i - 1] + dist(pts[i - 1], pts[i])
        val target = cum.last() * fraction.coerceIn(0.0, 1.0)
        val out = mutableListOf(pts[0])
        for (i in 1 until pts.size) {
            if (cum[i] <= target) {
                out.add(pts[i])
            } else {
                val seg = cum[i] - cum[i - 1]
                val t = if (seg <= 0) 0.0 else (target - cum[i - 1]) / seg
                out.add(floatArrayOf((pts[i - 1][0] + (pts[i][0] - pts[i - 1][0]) * t).toFloat(), (pts[i - 1][1] + (pts[i][1] - pts[i - 1][1]) * t).toFloat()))
                break
            }
        }
        return out
    }

    private fun dist(a: FloatArray, b: FloatArray): Double = sqrt(((a[0] - b[0]) * (a[0] - b[0]) + (a[1] - b[1]) * (a[1] - b[1])).toDouble())

    private fun poly(pts: List<FloatArray>) = Path().apply {
        pts.forEachIndexed { i, p -> if (i == 0) moveTo(p[0], p[1]) else lineTo(p[0], p[1]) }
    }

    /** The destination dot's radius on the mini map. */
    const val MINI_DEST_R = 6f

    /** Whether the mini map's grade pill (28 x 20, see [drawBadge]) at [steep] stays off the destination dot at [dest]. When
     * the steepest climb is at the end of the route the pill would lie under the dot, and the two together read as a pale
     * oval with a dot in it instead of a destination; the pill is then left out (the main map's badge and the climb card
     * still show the grade). */
    fun miniBadgeFits(steep: FloatArray, dest: FloatArray, d: Float): Boolean {
        val gap = 2f
        return abs(steep[0] - dest[0]) >= (14f + MINI_DEST_R + gap) * d || abs(steep[1] - dest[1]) >= (10f + MINI_DEST_R + gap) * d
    }

    fun drawMiniMap(canvas: Canvas, r: RectF, ov: CarOverview, pal: CarOverlayColors, d: Float) {
        val radius = 14f * d
        canvas.drawRoundRect(r, radius, radius, fill(pal.miniBg))
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(r, radius, radius, Path.Direction.CW) })
        // The steep point and destination are projected with the route so they share its frame.
        val extra = mutableListOf<DoubleArray>()
        if (ov.steepLat != null && ov.steepLon != null) extra.add(doubleArrayOf(ov.steepLat, ov.steepLon))
        val all = ov.points + extra
        val px = project(all, r, 24f * d)
        val route = px.subList(0, ov.points.size)
        canvas.drawPath(poly(route), stroke(pal.route, 5f * d))
        val driven = cut(route, ov.drivenFraction)
        if (driven.size >= 2) canvas.drawPath(poly(driven), stroke(pal.routeDriven, 5f * d))
        val end = route.last()
        if (extra.isNotEmpty() && ov.steepGradePct != null) {
            val s = px.last()
            if (miniBadgeFits(s, end, d)) drawBadge(canvas, s[0], s[1], null, pal, d)
        }
        val start = route.first()
        canvas.drawCircle(start[0], start[1], 5f * d, fill(pal.startDot))
        // The destination: a plain dot at the end of the line.
        canvas.drawCircle(end[0], end[1], MINI_DEST_R * d, fill(pal.destDot))
        val here = driven.last()
        canvas.drawCircle(here[0], here[1], 8f * d, fill(pal.posFill))
        canvas.drawCircle(here[0], here[1], 8f * d, stroke(pal.posRing, 3f * d))
        canvas.restore()
        canvas.drawRoundRect(RectF(r).apply { inset(d, d) }, radius, radius, stroke(pal.miniBorder, 2f * d))
    }
}

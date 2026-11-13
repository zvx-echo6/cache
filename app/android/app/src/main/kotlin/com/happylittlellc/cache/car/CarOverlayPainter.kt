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
 * Paints Cache's own pieces on the car's map: the route mini map and the climb ahead. Pure drawing: a Canvas, the trip's
 * blocks, a size, the host's areas and the density go in; nothing is read from the car, nothing moves, nothing is interactive.
 *
 * The pieces take the colors of the phone's chosen theme, from the trip's palette (the owner's decision of 2026-11-13: the car
 * follows the phone's theme, day and night): the card, its text, its outline, the route and the dots. Their shape is the host's
 * cards' (corner, outline width, text sizes). [HOST_STYLE] is only for a trip that has no palette yet.
 *
 * There are two layouts ([CarOverlayMode], chosen by [modeFor] from the stable area alone, so the choice holds for the whole
 * drive):
 *  - one box, on a screen whose left column has a tall enough gap between the host's turn card and its arrival card: the
 *    mini map on top and the climb under it (label, figure, grade line, shape), on the host cards' left edge, centred in the
 *    gap. With no climb to show it is the mini map alone, in the same place; with no route shape to show, the climb
 *    alone, where the box's lower part is.
 *  - split, everywhere else: the climb is a one-line card in that gap, as wide as the host's cards; the mini map is a tile in
 *    the bottom right corner of the visible area, full size or two thirds, whichever keeps clear of the vehicle.
 *
 * No piece ever lies over the vehicle. While guiding, the camera (CarMapRenderer.follow) puts the position marker at
 * [vehiclePoint] of the stable area, and the road ahead runs up the screen from it. [keepClear] is that marker and the column
 * above it; a piece that would reach into it is not drawn. The camera is not moved to make room.
 */
object CarOverlayPainter {
    // ---- layout (mock pixels at density 1.0) ---------------------------------------------------------------------
    const val MARGIN = 16f

    /** The smallest text the host itself draws on the guidance screen (the second line of its estimate card and the next
     * step: 24 px at density 1.0, measured on the car simulator). No text on the pieces is smaller. (Declared before
     * every size that is set from it.) */
    const val HOST_MIN_TEXT = 24f

    // ---- the look: the host's own cards. Measured on the desktop head unit (DHU 2.0, 1280 x 720 at 160 dpi, Android Auto
    // ---- 17.9); the host's cards had these colors by day and by night there. Correct them here after a real car.

    /** The host's arrival card: its fill, its 2 px outline, its corner radius; its first line's text and its second line's. */
    const val HOST_CARD_FILL = 0xFF242627.toInt()
    const val HOST_CARD_EDGE = 0xFF45474B.toInt()
    const val HOST_CARD_RADIUS = 22f
    const val HOST_CARD_EDGE_W = 2f
    const val HOST_TEXT = 0xFFFFFFFF.toInt()
    const val HOST_TEXT_SECONDARY = 0xFFC7CBD1.toInt()

    /** On that dark ground: the route (the light blue of the app's dark map), the part already driven, and the dots. */
    const val ON_DARK_ROUTE = 0xFF6BB4DE.toInt()
    const val ON_DARK_DRIVEN = 0xFF5A6672.toInt()
    const val ON_DARK_START = 0xFF8A96A3.toInt()

    /** The colors for a trip that carries no palette (none has come from the phone yet): dark cards like the host's. A trip
     * with a palette is painted in it ([colorsFor]). */
    val HOST_STYLE = CarOverlayColors(
        theme = "host", route = ON_DARK_ROUTE, routeDriven = ON_DARK_DRIVEN, badge = 0xFFF4F6F8.toInt(), badgeGlyph = 0xFF161B20.toInt(),
        badgeEdge = HOST_CARD_FILL, startDot = ON_DARK_START, destDot = HOST_TEXT, posFill = HOST_TEXT, posRing = ON_DARK_ROUTE,
        card = HOST_CARD_FILL, cardText = HOST_TEXT, cardSecondary = HOST_TEXT_SECONDARY, hatch = HOST_TEXT, miniBg = HOST_CARD_FILL,
        miniBorder = HOST_CARD_EDGE, hostCard = HOST_CARD_FILL,
    )

    // ---- the one box ---------------------------------------------------------------------------------------------------

    /** The box's width. The mini map alone was 220; the climb's lines at the host's smallest text size need more: the grade
     * line ("11% in 123.4 mi", 24 px semibold) measures up to about 175, and the figure (34 px bold, up to about 145) has the
     * shape beside it, which needs [SHAPE_MIN_W]. 260 less the padding on both sides leaves 232: the longest line with room
     * to spare, and 75 or more for the shape. */
    const val BOX_W = 260f

    /** The mini map's height in the box, and the corner tile's full size. */
    const val MINI_H = 140f
    const val MINI_W = 220f

    /** The corner tile's smaller size, as a share of the full one. */
    const val MINI_SMALL = 2f / 3f

    /** The climb part's height: [BOX_PAD_TOP], the label, [CLIMB_FIGURE_DROP] to the figure, [CLIMB_GRADE_DROP] to the grade
     * line, and 16 under it. */
    const val BOX_CLIMB_H = 116f
    const val BOX_PAD_X = 14f
    const val BOX_PAD_TOP = 10f

    /** Between the climb's text and its shape. */
    const val CLIMB_GAP = 12f
    const val SHAPE_H = 52f

    // ---- the one-line climb card ---------------------------------------------------------------------------------------

    /** Its height (the shape's 52 with 6 above and below), its padding, the gap between its parts, and the least width of
     * column it is drawn in. */
    const val LINE_H = 64f
    const val LINE_PAD_X = 16f
    const val LINE_GAP = 12f
    const val LINE_MIN_W = 200f

    /** Its figure (bold) and its grade and distance: neither under the host's smallest text. The figure is smaller than in
     * the box (34) so that the figure, the grade and the distance fit the host cards' width on the smallest screen. */
    const val LINE_FIGURE_SIZE = 28f
    const val LINE_TEXT_SIZE = HOST_MIN_TEXT

    /** The widest the shape is drawn in the one-line card. */
    const val LINE_SHAPE_W = 84f

    /** Where the shape starts from the card's left edge: past the rounded corner ([HOST_CARD_RADIUS]) with room for its start
     * dot, so the dot does not sit on the corner. (It started at [LINE_PAD_X], on the corner.) */
    const val LINE_SHAPE_INSET = 28f

    /** The shape in the one-line card is the line alone, without the fill under it: in a card 64 high the fill was a block
     * against the card's edge. (The box's shape keeps its fill.) */
    const val LINE_SHAPE_FILLED = false

    /** The least free space above and below the one-line card in the gap. With less, no climb is drawn. */
    const val LINE_CUSHION_MIN = 12f

    /** The owner's number (2026-11-11): the shape's full height stands for at least this much rise, in meters (about 330 ft),
     * within the stretch shown. A stretch that rises less is drawn as if it rose this much, so a small rise draws low and a
     * flat road draws flat; a stretch that rises more is drawn to its own range. Change it here and nowhere else. */
    const val SHAPE_MIN_RISE_M = 100.0

    /** The narrowest shape still worth drawing beside the text. */
    const val SHAPE_MIN_W = 60f

    /** The climb's three lines: the label, the figure (bold) and the grade line (semibold). The mock had 13, 26 and 15;
     * the label and the grade line were raised to the host's smallest size, and the figure to 34 so it still reads as the
     * main thing beside them. */
    const val CLIMB_LABEL_SIZE = HOST_MIN_TEXT
    const val CLIMB_FIGURE_SIZE = 34f
    const val CLIMB_GRADE_SIZE = HOST_MIN_TEXT

    /** From the label's baseline down to the figure's, and from the figure's down to the grade line's. */
    const val CLIMB_FIGURE_DROP = 37f
    const val CLIMB_GRADE_DROP = 29f

    // ---- the host's left column. The host does not tell the app where its cards are. These are measured on the desktop head
    // ---- unit (DHU 2.0 at 160 dpi, Android Auto 17.9) in density-independent pixels; correct them after a real car.

    /** The host's turn card and arrival card: their width where the screen has room, and the gap between their right edge
     * and the visible (and stable) area's left edge. Measured at 1280 x 720: the cards run from x 92 to 492, the area starts
     * at about 505. */
    const val HOST_CARD_W = 400f
    const val HOST_COLUMN_GAP = 14f

    /** The least the host keeps between its cards and the edge of the screen. Measured at 800 x 480, where the cards are
     * narrower and run from x 12 to 332. */
    const val HOST_EDGE_GAP = 12f

    /** From the stable area's top down to the bottom of the turn card in the tallest state seen: a two-line road name and
     * the next-step row. Measured: the card ends at y 212 at 1280 x 720 and at 202 at 800 x 480, with the stable area
     * starting at about 91 and 81. (With a one-line road name it ended at 180 on the wide screen.) */
    const val TURN_CARD_BELOW_TOP = 121f

    /** The arrival (travel estimate) card's height; its bottom is the stable area's bottom. Measured: y 615 to 697 at
     * 1280 x 720, 305 to 388 at 800 x 480. */
    const val ARRIVAL_CARD_H = 83f

    /** The least free space above and below the whole box in the left column, so a card that grows does not reach it. With
     * less, the layout is the split one. (1280 x 720 has about 73 each side.) */
    const val BOX_CUSHION_MIN = 40f

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

    /** Where the pieces go, in surface pixels; null for a piece that is off or does not fit. In [CarOverlayMode.ONE_BOX] the
     * [mini] map and the [climb] are the two parts of one box, the climb right under the mini map ([box] is their common
     * outline); in [CarOverlayMode.SPLIT] the climb is the one-line card and the mini map is the corner tile. */
    data class Layout(val mode: CarOverlayMode, val mini: RectF?, val climb: RectF?) {
        val box: RectF?
            get() = when {
                mode != CarOverlayMode.ONE_BOX -> null
                mini != null && climb != null -> RectF(mini.left, mini.top, climb.right, climb.bottom)
                else -> mini ?: climb
            }
    }

    /** The gap in the host's left column between its turn card and its arrival card, top and bottom, as estimated from
     * [area] (the stable area) and the measured constants. */
    fun columnGap(area: Rect, density: Float): Pair<Float, Float> =
        Pair(area.top + TURN_CARD_BELOW_TOP * density, area.bottom - ARRIVAL_CARD_H * density)

    /** The host cards' left and right edges: the right one [HOST_COLUMN_GAP] left of [area], the left one [HOST_CARD_W]
     * further, and never nearer the screen's edge than [HOST_EDGE_GAP] (on a narrower screen the cards are narrower). */
    fun column(area: Rect, density: Float): Pair<Float, Float> {
        val right = area.left - HOST_COLUMN_GAP * density
        return Pair(max(right - HOST_CARD_W * density, HOST_EDGE_GAP * density), right)
    }

    /**
     * Which layout a screen gets. [area] is the stable area (falling back as in [layout]); the visible area's right edge,
     * which moves when the host shows and hides its buttons, plays no part, so the choice holds for the whole drive.
     *
     * [CarOverlayMode.ONE_BOX] when the left column is wide enough for the box and the gap between the host's two cards
     * holds the WHOLE box (mini map and climb) with [BOX_CUSHION_MIN] above and below. The whole box decides even while only
     * one part is drawn, so the layout never changes when a climb comes or goes. Otherwise [CarOverlayMode.SPLIT].
     */
    fun modeFor(area: Rect, density: Float): CarOverlayMode {
        val d = density
        val (gapTop, gapBottom) = columnGap(area, d)
        val (left, right) = column(area, d)
        val wide = right - left >= BOX_W * d
        val high = gapBottom - gapTop >= (MINI_H + BOX_CLIMB_H + 2 * BOX_CUSHION_MIN) * d
        return if (wide && high) CarOverlayMode.ONE_BOX else CarOverlayMode.SPLIT
    }

    /**
     * Where the pieces go. [visible] is the area the host says is free of its own parts (it changes as the host shows and
     * hides its buttons); [stable] is the area the camera places the vehicle in. Each falls back to the other, then to the
     * whole surface, as CarMapRenderer.follow does. Every piece is inside the surface and clear of [keepClear].
     *
     * One box: on the host cards' left edge, the whole box centred in the gap between the turn card and the arrival card,
     * on whole pixels. Each part keeps its place in the whole box when the other is not drawn: the mini map alone is the
     * upper part (it does not move when a climb comes or goes), the climb alone the lower part.
     * All of that is estimated ([column], [columnGap]): a turn card taller than the tallest seen (three lines, lanes, a
     * junction picture) uses up the cushion above the box and then lies over its top, since the host draws above the app.
     *
     * Split: the climb is a one-line card across the host cards' width, centred in the same gap, when the gap holds it with
     * [LINE_CUSHION_MIN] above and below. The mini map is a tile in the visible area, its bottom [MARGIN] above the area's
     * bottom and its right edge on the area's right edge (beside the host's map buttons while they show). It is full size
     * where that clears the vehicle and the road ahead, [MINI_SMALL] of it where only that does, and not drawn otherwise.
     * Its size is settled where the buttons show (against the stable area's right edge), so it does not change size when
     * they hide; it only slides to the wider area's edge.
     */
    fun layout(width: Int, height: Int, visible: Rect?, density: Float, showClimb: Boolean, showMini: Boolean, stable: Rect? = null): Layout {
        val full = Rect(0, 0, width, height)
        val area = Rect(visible ?: stable ?: full).also { it.intersect(0, 0, width, height) }
        val cam = stable ?: visible ?: full
        val d = density
        val mode = modeFor(cam, d)
        val keep = keepClear(cam, d)
        fun fits(r: RectF) = r.left >= 0f && r.top >= 0f && r.right <= width && r.bottom <= height && !RectF.intersects(r, keep)
        val (gapTop, gapBottom) = columnGap(cam, d)
        val (colLeft, colRight) = column(cam, d)
        val left = colLeft.roundToInt().toFloat()

        if (mode == CarOverlayMode.ONE_BOX) {
            // The whole box is placed, whatever is drawn: each part keeps its place in it, so the mini map does not move
            // when a climb comes into range or ends. The box only grows and shrinks downward.
            val top = ((gapTop + gapBottom - (MINI_H + BOX_CLIMB_H) * d) / 2f).roundToInt().toFloat()
            val whole = RectF(left, top, left + BOX_W * d, top + (MINI_H + BOX_CLIMB_H) * d)
            if (!fits(whole)) return Layout(mode, null, null)
            val split = top + MINI_H * d
            return Layout(
                mode,
                mini = if (showMini) RectF(whole.left, whole.top, whole.right, split) else null,
                climb = if (showClimb) RectF(whole.left, split, whole.right, whole.bottom) else null,
            )
        }

        var climb: RectF? = null
        if (showClimb) {
            val h = LINE_H * d
            if (colRight - left >= LINE_MIN_W * d && gapBottom - gapTop >= h + 2 * LINE_CUSHION_MIN * d) {
                val top = ((gapTop + gapBottom - h) / 2f).roundToInt().toFloat()
                climb = RectF(left, top, colRight, top + h).takeIf { fits(it) }
            }
        }
        var mini: RectF? = null
        if (showMini && !area.isEmpty) {
            val bottom = area.bottom - MARGIN * d
            val tight = min(area.right, cam.right).toFloat()
            for (scale in listOf(1f, MINI_SMALL)) {
                val w = (MINI_W * d * scale).roundToInt().toFloat()
                val h = (MINI_H * d * scale).roundToInt().toFloat()
                val r = RectF(area.right - w, bottom - h, area.right.toFloat(), bottom)
                if (r.left >= area.left && r.top >= area.top && fits(RectF(tight - w, bottom - h, tight, bottom)) && fits(r)) {
                    mini = r
                    break
                }
            }
        }
        return Layout(mode, mini, climb)
    }

    // ---- the screen's class: whether the two extras are drawn at all -------------------------------------------------

    /** The most of the free map the two extras may take on a screen that always carries them: at or below 15 % the screen
     * is big, above it in-between (set 2026-11-12 so that the wide, short screens are the in-between ones: 1280 x 500
     * measures 16.9 %, 1280 x 720 measures 11.7 %). Change it here and nowhere else. */
    const val EXTRAS_BIG_MAX_SHARE = 0.15f

    /** What [extrasMeasure] found: the class, whether both extras fit at full size, the pixels they take and the pixels of
     * free map. */
    data class ExtrasMeasure(val cls: CarExtrasClass, val fits: Boolean, val extrasPx: Float, val freePx: Float) {
        val share: Float get() = if (freePx > 0f) extrasPx / freePx else 1f
    }

    /** The class from the two figures of the measure. */
    fun extrasClass(fits: Boolean, extrasPx: Float, freePx: Float): CarExtrasClass = when {
        !fits || freePx <= 0f -> CarExtrasClass.SMALL
        extrasPx > EXTRAS_BIG_MAX_SHARE * freePx -> CarExtrasClass.IN_BETWEEN
        else -> CarExtrasClass.BIG
    }

    /** The host's band of buttons along the top of the guidance screen (End route and the others): the stable area starts
     * this far below the surface's top while they show. Measured on the car simulator: 91 at 1280 x 720 (2026-11) and on all
     * three surfaces of session 95 (1190 x 480, 1190 x 700, 1816 x 1056). */
    const val HOST_TOP_BAND = 91f

    /** The host's column of map buttons on the right (zoom in and out): the stable area ends at least this far from the
     * surface's right edge while they show. Measured: 103 at 1280 x 720, 106 on the three surfaces of session 95. */
    const val HOST_RIGHT_BAND = 103f

    /**
     * The room the screen's class is measured on: the stable area (falling back as in [layout]), never reaching into the
     * host's top band ([HOST_TOP_BAND]) or its map buttons' column ([HOST_RIGHT_BAND]). The host takes those buttons away
     * after a few seconds without a touch and brings them back with a new screen (a re-route, a new instruction), and it
     * reports a larger stable area while they are away: on the car simulator the 1190 x 480 surface's stable area grew from
     * 658 x 376 to 658 x 440 and back every few seconds of a drive. Measured on the room as it is with the buttons showing,
     * the class is the same in both states, so it holds for the whole drive.
     */
    fun steadyArea(width: Int, height: Int, visible: Rect?, density: Float, stable: Rect? = null): Rect {
        val r = Rect(stable ?: visible ?: Rect(0, 0, width, height))
        r.top = max(r.top, (HOST_TOP_BAND * density).roundToInt())
        r.right = min(r.right, width - (HOST_RIGHT_BAND * density).roundToInt())
        return r
    }

    /**
     * How the two extras fit this screen, from the room the car reports: [steadyArea], the stable area as it is with the
     * host's buttons showing. The visible area's right edge moves when the host shows and hides its buttons and plays no
     * part, and neither does the stable area's growing while they are away, so the class holds for the whole drive.
     *
     * They FIT when [layout] places both of them, with both asked for, at their full size and clear of the vehicle and the
     * road ahead: the whole box (one-box layout), or the one-line climb card and the full-size corner tile (split layout).
     * A screen that only has room for the smaller tile, or for one of the two, does not fit them.
     *
     * The FREE MAP is the map the host leaves uncovered: the stable area (the car's free room, already less the host's
     * cards and its buttons) and the gap in the host's left column between its turn card and its arrival card
     * ([column], [columnGap]), where the map also shows.
     *
     * The extras TAKE the area of the pieces as placed. Small: they do not fit. In-between: they take more than
     * [EXTRAS_BIG_MAX_SHARE] of the free map. Big: otherwise.
     */
    fun extrasMeasure(width: Int, height: Int, visible: Rect?, density: Float, stable: Rect? = null): ExtrasMeasure {
        val full = Rect(0, 0, width, height)
        val cam = steadyArea(width, height, visible, density, stable)
        val d = density
        val l = layout(width, height, cam, d, showClimb = true, showMini = true, stable = cam)
        val mini = l.mini
        val climb = l.climb
        val fullSize = mini != null && (l.mode == CarOverlayMode.ONE_BOX || mini.height() >= MINI_H * d - 1f)
        val fits = climb != null && fullSize
        val box = l.box
        val extras = when {
            box != null -> box.width() * box.height()
            else -> (mini?.let { it.width() * it.height() } ?: 0f) + (climb?.let { it.width() * it.height() } ?: 0f)
        }
        val inside = Rect(cam).also { if (!it.intersect(full)) it.setEmpty() }
        val (gapTop, gapBottom) = columnGap(cam, d)
        val (colLeft, colRight) = column(cam, d)
        val gap = max(0f, colRight - colLeft) * max(0f, gapBottom - gapTop)
        val free = inside.width().toFloat() * inside.height().toFloat() + gap
        return ExtrasMeasure(extrasClass(fits, extras, free), fits, extras, free)
    }

    /** The pieces for [trip], each where it has its data. Whether they are drawn at all on this screen, and how opaque, is
     * the view's (the screen's class and the fade, CarOverlayView). Nothing is drawn unless the trip is guiding, and nothing while
     * the route overview screen is up ([overview]): the mini map would repeat what that screen's map already shows. The
     * climb is never drawn on arrival (the phone sends no climb then; this holds for a trip that still carries one). */
    fun draw(
        canvas: Canvas, trip: CarTrip, width: Int, height: Int, visible: Rect?, density: Float, stable: Rect? = null, overview: Boolean = false,
        lineShapeFilled: Boolean = LINE_SHAPE_FILLED, lineShapeInset: Float = LINE_SHAPE_INSET,
    ) {
        if (!trip.guiding || overview) return
        val climb = if (!trip.arrived) trip.climb else null
        val ov = trip.overview
        val l = layout(width, height, visible, density, showClimb = climb != null, showMini = ov != null, stable = stable)
        val d = density
        val pal = colorsFor(trip)
        val box = l.box
        if (box != null) {
            // One box: one card, the mini map in its upper part (on the theme's page color, as the mini map tile), a thin
            // divider, the climb in its lower part (on the card color).
            drawCard(canvas, box, pal, d)
            canvas.save()
            canvas.clipPath(Path().apply { addRoundRect(box, HOST_CARD_RADIUS * d, HOST_CARD_RADIUS * d, Path.Direction.CW) })
            if (l.mini != null && ov != null) {
                canvas.save()
                canvas.clipRect(l.mini)
                canvas.drawRect(l.mini, fill(pal.miniBg))
                drawMiniContent(canvas, l.mini, ov, pal, d)
                canvas.restore()
            }
            if (l.climb != null && climb != null) {
                drawClimbPart(canvas, l.climb, climb, trip.imperial, pal, d)
                if (l.mini != null) canvas.drawRect(l.climb.left, l.climb.top, l.climb.right, l.climb.top + max(1f, d), fill(pal.miniBorder))
            }
            canvas.restore()
            drawCardEdge(canvas, box, pal, d)
            return
        }
        if (l.climb != null && climb != null) drawClimbLine(canvas, l.climb, climb, trip.imperial, pal, d, lineShapeFilled, lineShapeInset)
        if (l.mini != null && ov != null) drawMiniMap(canvas, l.mini, ov, pal, d, scale = l.mini.height() / (MINI_H * d))
    }

    /** The colors the pieces are painted in: the trip's palette (the phone's chosen theme), or [HOST_STYLE] before one came. */
    fun colorsFor(trip: CarTrip): CarOverlayColors = trip.palette ?: HOST_STYLE

    /** A card in the host's shape: the fill, and over the content the outline. */
    private fun drawCard(canvas: Canvas, r: RectF, pal: CarOverlayColors, d: Float) {
        canvas.drawRoundRect(r, HOST_CARD_RADIUS * d, HOST_CARD_RADIUS * d, fill(pal.card))
    }

    private fun drawCardEdge(canvas: Canvas, r: RectF, pal: CarOverlayColors, d: Float) {
        val w = HOST_CARD_EDGE_W * d
        canvas.drawRoundRect(RectF(r).apply { inset(w / 2, w / 2) }, HOST_CARD_RADIUS * d - w / 2, HOST_CARD_RADIUS * d - w / 2, stroke(pal.miniBorder, w))
    }

    // ---- the climb part -----------------------------------------------------------------------------------------------

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

    /** The climb inside the box's lower part [r] (no background of its own): the label, the figure in bold and the grade line
     * in semibold one under the other, and the shape right of the label and the figure. The shape takes what those two leave
     * (a long figure makes it narrower) and is left out when that is under half of [SHAPE_MIN_W]. */
    fun drawClimbPart(canvas: Canvas, r: RectF, c: CarClimb, imperial: Boolean, pal: CarOverlayColors, d: Float) {
        val x0 = r.left + BOX_PAD_X * d
        val labelPaint = text(pal.cardSecondary, CLIMB_LABEL_SIZE * d, 400)
        val figurePaint = text(pal.cardText, CLIMB_FIGURE_SIZE * d, 700)
        val gradePaint = text(pal.cardText, CLIMB_GRADE_SIZE * d, 600)
        val label = "Climb ahead"
        val figure = climbText(c.climbAheadM, imperial)
        val labelY = r.top + (BOX_PAD_TOP + CLIMB_LABEL_SIZE) * d
        val figureY = labelY + CLIMB_FIGURE_DROP * d
        canvas.drawText(label, x0, labelY, labelPaint)
        canvas.drawText(figure, x0, figureY, figurePaint)
        val g = c.gradePct
        val into = c.steepestInM
        if (g != null && into != null) {
            canvas.drawText("${gradeText(g)} in ${aheadText(into, imperial)}", x0, figureY + CLIMB_GRADE_DROP * d, gradePaint)
        }
        val shapeRight = r.right - BOX_PAD_X * d
        val shapeLeft = x0 + max(labelPaint.measureText(label), figurePaint.measureText(figure)) + CLIMB_GAP * d
        if (shapeRight - shapeLeft < SHAPE_MIN_W * d * 0.5f) return
        // Level with the label and the figure: from the label's top to the figure's baseline, the shape in the middle.
        val mid = (r.top + BOX_PAD_TOP * d + figureY) / 2f
        drawShape(canvas, RectF(shapeLeft, mid - SHAPE_H * d / 2, shapeRight, mid + SHAPE_H * d / 2), c, pal, d)
    }

    /** What the one-line card holds, most first. */
    enum class LineForm { SHAPE_FIGURE_GRADE_DISTANCE, FIGURE_GRADE_DISTANCE, FIGURE_GRADE, FIGURE }

    /** What a line [avail] wide holds at the fixed text sizes: the figure always; then the grade; then the distance; the
     * shape (at least [SHAPE_MIN_W]) only when all three fit beside it. So the shape is the first to go and the distance
     * the next. The widths are the texts as measured; [gradeDistanceW] and [gradeW] are null with no grade to show. */
    fun lineForm(avail: Float, figureW: Float, gradeDistanceW: Float?, gradeW: Float?, d: Float): LineForm {
        val gap = LINE_GAP * d
        if (gradeDistanceW != null) {
            // The shape starts further in than the text would ([LINE_SHAPE_INSET]), which is that much less room.
            val inset = (LINE_SHAPE_INSET - LINE_PAD_X) * d
            if (inset + SHAPE_MIN_W * d + gap + figureW + gap + gradeDistanceW <= avail) return LineForm.SHAPE_FIGURE_GRADE_DISTANCE
            if (figureW + gap + gradeDistanceW <= avail) return LineForm.FIGURE_GRADE_DISTANCE
        }
        if (gradeW != null && figureW + gap + gradeW <= avail) return LineForm.FIGURE_GRADE
        return LineForm.FIGURE
    }

    /** The climb as a one-line card [r] in the host's style: the shape, the figure in bold, then the grade and how far, in
     * the same words and number formats as the box ("2,130 ft", "11% in 23.0 mi", or "11%" alone). See [lineForm].
     * [shapeFilled] and [shapeInset] are the shape's look and where it starts; the defaults are what the car draws (the
     * tests paint the other choice beside it). */
    fun drawClimbLine(
        canvas: Canvas, r: RectF, c: CarClimb, imperial: Boolean, pal: CarOverlayColors, d: Float,
        shapeFilled: Boolean = LINE_SHAPE_FILLED, shapeInset: Float = LINE_SHAPE_INSET,
    ) {
        drawCard(canvas, r, pal, d)
        val figurePaint = text(pal.cardText, LINE_FIGURE_SIZE * d, 700)
        val textPaint = text(pal.cardSecondary, LINE_TEXT_SIZE * d, 400)
        val figure = climbText(c.climbAheadM, imperial)
        val g = c.gradePct
        val into = c.steepestInM
        val grade = if (g != null) gradeText(g) else null
        val gradeDistance = if (g != null && into != null) "${gradeText(g)} in ${aheadText(into, imperial)}" else null
        val figureW = figurePaint.measureText(figure)
        val avail = r.width() - 2 * LINE_PAD_X * d
        val form = lineForm(avail, figureW, gradeDistance?.let { textPaint.measureText(it) }, grade?.let { textPaint.measureText(it) }, d)
        val second = when (form) {
            LineForm.SHAPE_FIGURE_GRADE_DISTANCE, LineForm.FIGURE_GRADE_DISTANCE -> gradeDistance
            LineForm.FIGURE_GRADE -> grade
            LineForm.FIGURE -> null
        }
        var x = r.left + LINE_PAD_X * d
        val gap = LINE_GAP * d
        if (form == LineForm.SHAPE_FIGURE_GRADE_DISTANCE && second != null) {
            x = r.left + shapeInset * d
            val w = min(LINE_SHAPE_W * d, r.right - LINE_PAD_X * d - x - figureW - textPaint.measureText(second) - 2 * gap)
            drawShape(canvas, RectF(x, r.centerY() - SHAPE_H * d / 2, x + w, r.centerY() + SHAPE_H * d / 2), c, pal, d, filled = shapeFilled)
            x += w + gap
        }
        // Both texts on one baseline: half the figure's digit height (about 0.71 of its size) under the middle.
        val baseline = r.centerY() + LINE_FIGURE_SIZE * 0.355f * d
        canvas.drawText(figure, x, baseline, figurePaint)
        if (second != null) canvas.drawText(second, x + figureW + gap, baseline, textPaint)
        drawCardEdge(canvas, r, pal, d)
    }

    /** Where a height is drawn in the shape, between [top] (high) and [bottom] (low), for a stretch whose heights run from
     * [lo] to [hi]. The whole height stands for the stretch's own range, or for [SHAPE_MIN_RISE_M] when the range is less; the
     * middle of the range is drawn at the middle, so a flat road is a level line there and a small rise stays close to it. */
    fun shapeY(heightM: Double, lo: Double, hi: Double, top: Float, bottom: Float): Float {
        val span = max(hi - lo, SHAPE_MIN_RISE_M)
        return (top + bottom) / 2f - (((heightM - (lo + hi) / 2.0) / span) * (bottom - top)).toFloat()
    }

    /** The shape of the road ahead, no axes: lightly filled under a line ([filled]; without it the line alone), a dot at the
     * start, the steepest stretch hatched. */
    fun drawShape(canvas: Canvas, box: RectF, c: CarClimb, pal: CarOverlayColors, d: Float, filled: Boolean = true) {
        val n = c.heightsM.size
        val lo = c.heightsM.min()
        val hi = c.heightsM.max()
        // The mock's shape runs from y 48 (low) to y 5 (high) in a 52 high box; a flat road sits in the lower middle.
        val top = box.top + 5f * d
        val bottomY = box.top + 48f * d
        fun xAt(i: Int) = box.left + box.width() * i / (n - 1)
        fun yAt(i: Int): Float = shapeY(c.heightsM[i], lo, hi, top, bottomY)
        val line = Path().apply {
            moveTo(xAt(0), yAt(0))
            for (i in 1 until n) lineTo(xAt(i), yAt(i))
        }
        val area = Path(line).apply {
            lineTo(xAt(n - 1), box.bottom)
            lineTo(xAt(0), box.bottom)
            close()
        }
        if (filled) canvas.drawPath(area, fill(withAlpha(pal.route, 0.22f)))
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

    /** The main map's destination marker (the car-dest layer: a dot of radius 9 with a ring of 3), and the least free map
     * between it, or the route's end, and the grade badge. */
    const val DEST_MARKER_R = 12f
    const val BADGE_CLEAR = 4f

    /**
     * How far the main map's grade badge is moved from its point so it does not cover the destination: (0, 0) when it is
     * clear, else straight up the screen until it is. [steep] is the badge's point and [ends] the destination marker and the
     * route's end, all in screen pixels; [badgeW] is the badge's width in pixels. The badge covered the destination dot
     * whenever the steepest stretch was at the end of the route, most plainly on the route overview.
     */
    fun badgeOffset(steep: PointF, ends: List<PointF>, badgeW: Float, d: Float): PointF {
        val halfW = badgeW / 2f
        val halfH = BADGE_H * d / 2f
        val reach = (DEST_MARKER_R + BADGE_CLEAR) * d
        var cy = steep.y
        // Each pass lifts the badge clear of what it touches; what it cleared stays clear, so one pass per end is enough.
        repeat(ends.size) {
            val hit = ends.filter { abs(it.x - steep.x) < halfW + reach && abs(it.y - cy) < halfH + reach }
            if (hit.isEmpty()) return PointF(0f, cy - steep.y)
            cy = hit.minOf { it.y } - reach - halfH
        }
        return PointF(0f, cy - steep.y)
    }

    /** The main map's badge as a picture (a MapLibre symbol image). The picture says it is drawn at [d], as the arrow's does:
     * MapLibre scales a picture by the density it carries, and a new bitmap carries the phone's own, so without this the
     * badge came out smaller than these sizes wherever the phone's screen is denser than the car's. */
    fun badgeBitmap(gradePct: Double, pal: CarOverlayColors, d: Float): Bitmap {
        val w = ceil(badgeWidth(gradeText(gradePct), d)).toInt() + 4
        val h = (BADGE_H * d).toInt() + 4
        val bmp = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
        drawBadge(Canvas(bmp), w / 2f, h / 2f, gradeText(gradePct), pal, d)
        bmp.density = (160f * d).roundToInt()
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

    /** The mini map as a tile of its own, in the host's card shape: the theme's page color, the content, the outline. [scale] is the
     * tile's size against the full one (the lines, the dots and the padding shrink with it; the card's outline and corner do
     * not). */
    fun drawMiniMap(canvas: Canvas, r: RectF, ov: CarOverview, pal: CarOverlayColors, d: Float, scale: Float = 1f) {
        val radius = HOST_CARD_RADIUS * d
        canvas.drawRoundRect(r, radius, radius, fill(pal.miniBg))
        canvas.save()
        canvas.clipPath(Path().apply { addRoundRect(r, radius, radius, Path.Direction.CW) })
        drawMiniContent(canvas, r, ov, pal, d * scale)
        canvas.restore()
        val w = HOST_CARD_EDGE_W * d
        canvas.drawRoundRect(RectF(r).apply { inset(w / 2, w / 2) }, radius - w / 2, radius - w / 2, stroke(pal.miniBorder, w))
    }

    /** The route, the driven part, the grade pill and the three dots in [r]; the caller clips. */
    fun drawMiniContent(canvas: Canvas, r: RectF, ov: CarOverview, pal: CarOverlayColors, d: Float) {
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
    }
}

package com.happylittlellc.cache.car

import kotlin.math.cos
import kotlin.math.sqrt

/**
 * How the vehicle's marker moves on the car's map between one position and the next (CarMapRenderer draws it). Pure sums, no
 * map: where the marker is part of the way from one position to the next, how long the way takes, when it jumps instead, and
 * which heading the arrow shows.
 */
object CarMarkerMotion {
    /** The longest a glide from one position to the next takes. */
    const val MAX_GLIDE_MS = 1200L

    /** Positions further apart in time than this are not joined by a glide: the marker was not seen moving between them. */
    const val SNAP_GAP_MS = 3000L

    /** Positions further apart than this are not joined by a glide either (a new GPS lock, a test drive starting elsewhere). */
    const val SNAP_JUMP_M = 150.0

    /** The least time between two frames of a glide that are sent to the map: about 30 a second. A car's screen draws about
     * that many, each frame is a position for MapLibre's worker and a camera move, and the phone is also running an AI model,
     * so the frames the animator gives in between (60 or 120 a second) are let go. It is 30 and not 33 so that, on a phone that
     * gives a frame every 16 or 17 ms, every second frame passes whichever way the milliseconds round. */
    const val MIN_FRAME_MS = 30L

    /** Whether a frame of a glide is sent to the map: when at least [MIN_FRAME_MS] have passed since the last one that was
     * ([nowMs] and [lastAppliedMs] on one clock that only goes forward), and always for the last frame ([fraction] 1), so the
     * marker ends exactly on the position. A jump is not a frame and is never asked about here. */
    fun appliesFrame(fraction: Double, nowMs: Long, lastAppliedMs: Long): Boolean =
        fraction >= 1.0 || nowMs - lastAppliedMs >= MIN_FRAME_MS

    /** A heading as 0 up to (not including) 360 degrees. */
    fun norm(deg: Double): Double {
        val m = deg % 360.0
        return if (m < 0) m + 360.0 else m
    }

    /** How far apart two turns are, in degrees, the shorter way round (359 and 1 are 2 apart). */
    fun angleBetween(a: Double, b: Double): Double = kotlin.math.abs(((a - b) % 360.0 + 540.0) % 360.0 - 180.0)

    /** The arrow's turn on the screen, clockwise from straight up, for a vehicle heading [heading] on a map whose camera is
     * turned to [cameraBearing] (both compass degrees). The arrow's picture is tied to the screen, not to the map, so this is
     * the one number that turns it: while the camera is turned to the heading (guidance) it is 0 and stays 0 through every
     * corner, so the arrow and the map's rotation cannot come apart; with north up it is the heading itself. */
    fun arrowTurn(heading: Double, cameraBearing: Double): Double = norm(heading - cameraBearing)

    /** Whether the camera is turned to the vehicle's heading, so the arrow points straight up the screen (guidance). */
    fun arrowIsUp(heading: Double, cameraBearing: Double): Boolean = arrowTurn(heading, cameraBearing) == 0.0

    /** The heading the arrow shows: the one the phone [reported], or with none the [last] one known. Null when none was ever
     * known: then there is no arrow (a dot is drawn), because an arrow must not point in a made-up direction. */
    fun heading(reported: Double?, last: Double?): Double? =
        if (reported != null && !reported.isNaN() && !reported.isInfinite()) norm(reported) else last

    /** The same, for a trip that is [guiding] or not. While guiding, a position that comes without a heading keeps the last
     * one (the vehicle is on its route). At any other time a position without a heading has none: the vehicle is parked or
     * its course is not known, and the marker is the dot, after a drive as before the first one. */
    fun heading(reported: Double?, last: Double?, guiding: Boolean): Double? = heading(reported, if (guiding) last else null)

    /** The share [f] (0 to 1) of the way from [a] to [b]; exactly [a] at 0 and exactly [b] at 1. */
    fun lerp(a: Double, b: Double, f: Double): Double = if (f >= 1.0) b else if (f <= 0.0) a else a + (b - a) * f

    /** The share [f] of the turn from heading [a] to heading [b], the shorter way round (359 to 1 goes through 0, not back
     * through 180). */
    fun lerpHeading(a: Double, b: Double, f: Double): Double {
        if (f >= 1.0) return norm(b)
        if (f <= 0.0) return norm(a)
        val turn = ((b - a) % 360.0 + 540.0) % 360.0 - 180.0
        return norm(a + turn * f)
    }

    /** Meters between two positions, on a flat sheet (fine for the short hops this is asked about). The longitudes are taken
     * as they are, so two positions on either side of the 180 degree line read as far apart and are not glided between. */
    fun distanceM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val x = Math.toRadians(lon2 - lon1) * cos(Math.toRadians((lat1 + lat2) / 2.0))
        val y = Math.toRadians(lat2 - lat1)
        return sqrt(x * x + y * y) * 6_371_000.0
    }

    /** How long the glide to a new position takes: the time since the position before it ([gapMs]), so at a steady speed the
     * marker arrives as the next position does, but never longer than [MAX_GLIDE_MS]. */
    fun durationMs(gapMs: Long): Long = gapMs.coerceIn(0L, MAX_GLIDE_MS)

    /** Whether the marker jumps to a new position instead of gliding there, because a glide would show movement that did not
     * happen: the [first] position, positions more than [SNAP_GAP_MS] apart in time (or with no time between them) or more than
     * [SNAP_JUMP_M] apart on the ground, a change of the trip's phase, or the caller saying so ([force]). */
    fun snaps(first: Boolean, gapMs: Long, jumpM: Double, phaseChanged: Boolean, force: Boolean): Boolean =
        first || force || phaseChanged || gapMs <= 0L || gapMs > SNAP_GAP_MS || jumpM > SNAP_JUMP_M
}

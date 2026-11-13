package com.happylittlellc.cache.car

import android.graphics.Color

/**
 * The climb-ahead card and the route mini map as Dart sends them in the trip (lib/car/car_overlay.dart): plain data, painted
 * by [CarOverlayPainter]. Nothing here works anything out about the road.
 */
data class CarClimb(
    val climbAheadM: Double,
    val gradePct: Double?,
    val steepestInM: Double?,
    val heightsM: List<Double>,
    val steepFrom: Int?,
    val steepTo: Int?,
    val windowM: Double,
) {
    companion object {
        fun from(v: Any?): CarClimb? {
            val m = v.asMap() ?: return null
            val heights = (m["heightsM"] as? List<*>).orEmpty().mapNotNull { it.asDouble() }
            if (heights.size < 2) return null
            return CarClimb(
                climbAheadM = m["climbAheadM"].asDouble() ?: 0.0,
                gradePct = m["gradePct"].asDouble(),
                steepestInM = m["steepestInM"].asDouble(),
                heightsM = heights,
                steepFrom = (m["steepFrom"] as? Number)?.toInt(),
                steepTo = (m["steepTo"] as? Number)?.toInt(),
                windowM = m["windowM"].asDouble() ?: 0.0,
            )
        }
    }
}

/** The whole route simplified: points are (lat, lon). */
data class CarOverview(
    val points: List<DoubleArray>,
    val drivenFraction: Double,
    val steepLat: Double?,
    val steepLon: Double?,
    val steepGradePct: Double?,
    val destLat: Double?,
    val destLon: Double?,
) {
    companion object {
        fun from(v: Any?): CarOverview? {
            val m = v.asMap() ?: return null
            val pts = (m["points"] as? List<*>).orEmpty().mapNotNull { p ->
                val l = p as? List<*> ?: return@mapNotNull null
                val lat = l.getOrNull(0).asDouble() ?: return@mapNotNull null
                val lon = l.getOrNull(1).asDouble() ?: return@mapNotNull null
                doubleArrayOf(lat, lon)
            }
            if (pts.size < 2) return null
            val steep = m["steep"].asMap()
            val dest = m["destination"].asMap()
            return CarOverview(
                points = pts,
                drivenFraction = (m["drivenFraction"].asDouble() ?: 0.0).coerceIn(0.0, 1.0),
                steepLat = steep?.get("lat").asDouble(),
                steepLon = steep?.get("lon").asDouble(),
                steepGradePct = steep?.get("gradePct").asDouble(),
                destLat = dest?.get("lat").asDouble(),
                destLon = dest?.get("lon").asDouble(),
            )
        }
    }
}

/** The overlay's colors for one theme (ARGB ints), made from Dart's theme tokens: the car holds no palette of its own. */
data class CarOverlayColors(
    val theme: String,
    val route: Int,
    val routeDriven: Int,
    val badge: Int,
    val badgeGlyph: Int,
    val badgeEdge: Int,
    val startDot: Int,
    val destDot: Int,
    val posFill: Int,
    val posRing: Int,
    val card: Int,
    val cardText: Int,
    val cardSecondary: Int,
    val hatch: Int,
    val miniBg: Int,
    val miniBorder: Int,
    val hostCard: Int,
) {
    companion object {
        fun from(v: Any?): CarOverlayColors? {
            val m = v.asMap() ?: return null
            fun c(k: String): Int? = (m[k] as? String)?.let { try { Color.parseColor(it) } catch (e: IllegalArgumentException) { null } }
            return CarOverlayColors(
                theme = m["theme"] as? String ?: "",
                route = c("route") ?: return null, routeDriven = c("routeDriven") ?: return null,
                badge = c("badge") ?: return null, badgeGlyph = c("badgeGlyph") ?: return null, badgeEdge = c("badgeEdge") ?: return null,
                startDot = c("startDot") ?: return null, destDot = c("destDot") ?: return null,
                posFill = c("posFill") ?: return null, posRing = c("posRing") ?: return null,
                card = c("card") ?: return null, cardText = c("cardText") ?: return null, cardSecondary = c("cardSecondary") ?: return null,
                hatch = c("hatch") ?: return null, miniBg = c("miniBg") ?: return null, miniBorder = c("miniBorder") ?: return null,
                hostCard = c("hostCard") ?: return null,
            )
        }
    }
}

/** The colors for the car's day and its night. */
data class CarOverlayPalette(val day: CarOverlayColors, val night: CarOverlayColors) {
    fun forMode(dark: Boolean): CarOverlayColors = if (dark) night else day

    companion object {
        fun from(v: Any?): CarOverlayPalette? {
            val m = v.asMap() ?: return null
            return CarOverlayPalette(CarOverlayColors.from(m["day"]) ?: return null, CarOverlayColors.from(m["night"]) ?: return null)
        }
    }
}

/**
 * The trip's `overlay` part: the one thing the phone tells the car about its own screen. [phoneDrive] is true while the
 * phone's drive screen is showing to a person (phone unlocked, Cache in front, the Maps tab, a car connected and guiding);
 * a missing `overlay` or a missing value is false. The phone sends the plain truth at once; the pause and the fade are the
 * car's ([CarExtrasFade]). Whether the car draws its two extras at all is the screen's class ([CarExtrasClass]).
 */
data class CarOverlaySwitches(val phoneDrive: Boolean) {
    companion object {
        val DEFAULT = CarOverlaySwitches(phoneDrive = false)

        fun from(v: Any?): CarOverlaySwitches {
            val m = v.asMap() ?: return DEFAULT
            return CarOverlaySwitches(phoneDrive = m["phoneDrive"] == true)
        }
    }
}

/** What a car screen's free room allows for the two extras (the route mini map and the climb). Measured from the areas the car
 * reports, never from a list of sizes or models: [CarOverlayPainter.extrasMeasure]. */
enum class CarExtrasClass {
    /** The two extras do not both fit at their full size without covering the vehicle or the road ahead: never drawn. */
    SMALL,

    /** They fit, but take more than [CarOverlayPainter.EXTRAS_BIG_MAX_SHARE] of the free map: drawn, except while the
     * phone's drive screen is showing. */
    IN_BETWEEN,

    /** They fit and leave most of the free map: always drawn. */
    BIG;

    /** The word the phone is told for this class, so it knows whether to show the extras itself (the car channel's `extras`
     * method, `carries`): never on the car, on the car unless the phone's drive screen shows, always on the car. */
    val carries: String
        get() = when (this) {
            SMALL -> "never"
            IN_BETWEEN -> "unlessPhone"
            BIG -> "always"
        }

    /** Whether the extras are on the car, given whether the phone's drive screen is showing. */
    fun onCar(phoneDrive: Boolean): Boolean = when (this) {
        SMALL -> false
        IN_BETWEEN -> !phoneDrive
        BIG -> true
    }
}

/** How the car's two pieces (the route mini map and the climb) are laid out. [CarOverlayPainter.modeFor] chooses. */
enum class CarOverlayMode {
    /** One box in the host's left column: the mini map on top, the climb under it. */
    ONE_BOX,

    /** The climb as a one-line card in the host's left column, the mini map as a tile in the bottom right corner. */
    SPLIT,
}

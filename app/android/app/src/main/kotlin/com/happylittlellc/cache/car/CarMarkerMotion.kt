package com.happylittlellc.cache.car

/**
 * The vehicle's marker on the car's map (CarMapRenderer draws it). Pure sums, no map: which heading the arrow shows.
 */
object CarMarkerMotion {
    /** A heading as 0 up to (not including) 360 degrees. */
    fun norm(deg: Double): Double {
        val m = deg % 360.0
        return if (m < 0) m + 360.0 else m
    }

    /** The heading the arrow shows: the one the phone [reported], or with none the [last] one known. Null when none was ever
     * known: then there is no arrow (a dot is drawn), because an arrow must not point in a made-up direction. */
    fun heading(reported: Double?, last: Double?): Double? =
        if (reported != null && !reported.isNaN() && !reported.isInfinite()) norm(reported) else last
}

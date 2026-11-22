package com.happylittlellc.cache.car

import org.json.JSONObject
import kotlin.math.cos
import kotlin.math.sqrt

/** The route's line for the main map's driven part (grey): cut from the same GeoJSON the map draws the route from. */
object CarOverlayGeo {
    /** The chosen route's coordinates, (lon, lat) pairs in order, from the route GeoJSON (the features that are not alternatives). */
    fun mainRoute(geojson: String): List<DoubleArray> {
        val out = mutableListOf<DoubleArray>()
        try {
            val feats = JSONObject(geojson).optJSONArray("features") ?: return out
            for (i in 0 until feats.length()) {
                val f = feats.getJSONObject(i)
                if (f.optJSONObject("properties")?.optBoolean("alt", false) == true) continue
                val c = f.optJSONObject("geometry")?.optJSONArray("coordinates") ?: continue
                for (j in 0 until c.length()) {
                    val p = c.getJSONArray(j)
                    out.add(doubleArrayOf(p.getDouble(0), p.getDouble(1)))
                }
            }
        } catch (e: org.json.JSONException) {
            return emptyList()
        }
        return out
    }

    /** The first [fraction] of the line by length, as a GeoJSON LineString feature collection (empty when nothing is driven). */
    fun drivenGeoJson(coords: List<DoubleArray>, fraction: Double): String {
        val cut = cut(coords, fraction)
        if (cut.size < 2) return CarLink.EMPTY_GEOJSON
        val c = cut.joinToString(",") { "[${it[0]},${it[1]}]" }
        return "{\"type\":\"FeatureCollection\",\"features\":[{\"type\":\"Feature\",\"geometry\":{\"type\":\"LineString\",\"coordinates\":[$c]},\"properties\":{}}]}"
    }

    fun cut(coords: List<DoubleArray>, fraction: Double): List<DoubleArray> {
        if (coords.size < 2 || fraction <= 0.0) return emptyList()
        val k = cos(Math.toRadians(coords[0][1]))
        fun d(a: DoubleArray, b: DoubleArray): Double {
            val dx = (b[0] - a[0]) * k
            val dy = b[1] - a[1]
            return sqrt(dx * dx + dy * dy)
        }
        val cum = DoubleArray(coords.size)
        for (i in 1 until coords.size) cum[i] = cum[i - 1] + d(coords[i - 1], coords[i])
        val target = cum.last() * fraction.coerceAtMost(1.0)
        val out = mutableListOf(coords[0])
        for (i in 1 until coords.size) {
            if (cum[i] <= target) {
                out.add(coords[i])
            } else {
                val seg = cum[i] - cum[i - 1]
                val t = if (seg <= 0) 0.0 else (target - cum[i - 1]) / seg
                out.add(doubleArrayOf(coords[i - 1][0] + (coords[i][0] - coords[i - 1][0]) * t, coords[i - 1][1] + (coords[i][1] - coords[i - 1][1]) * t))
                break
            }
        }
        return out
    }
}
